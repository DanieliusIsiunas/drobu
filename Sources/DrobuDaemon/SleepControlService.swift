import Foundation
import DrobuShared

/// Implements the XPC contract. All mutable state (the watchdog + the state
/// file) is serialized by `lock`; the class is `@unchecked Sendable` on that
/// invariant — a lock-confined NSObject XPC service is the textbook case. XPC
/// methods are invoked by NSXPC on private connection queues (concurrent across
/// peers); each takes the lock, does its work, releases, then calls `reply`
/// synchronously so no reply block is captured into a `@Sendable` async closure
/// (avoids the Swift-6 sendability trap on `@objc` reply blocks).
final class SleepControlService: NSObject, DrobuDaemonXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.danielius.ClipboardHistory.daemon.watchdog")
    private var watchdog: Watchdog!
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        super.init()
        watchdog = Watchdog(queue: watchdogQueue) { [weak self] firingGeneration in
            self?.expire(firingGeneration: firingGeneration)
        }
    }

    /// Run once at startup: legacy sweep, then boot reconciliation.
    func startUp() {
        lock.lock(); defer { lock.unlock() }
        SleepStateStore.ensureSupportDirectory()
        LegacySweep.run()
        reconcileLocked()
    }

    // MARK: - XPC surface

    func enable(durationSeconds: Int, reply: @escaping (Bool, Int, Double) -> Void) {
        lock.lock()
        let n = now()
        let prior = SleepStateStore.read()

        if let rejection = RequestValidation.validate(durationSeconds: durationSeconds, now: n, priorState: prior) {
            lock.unlock()
            DaemonLog.write("SleepControlService: enable rejected (code \(rejection.enableResult.rawValue)) for \(durationSeconds)s")
            reply(false, rejection.enableResult.rawValue, 0)
            return
        }

        // Transactional: apply pmset first; on failure leave any prior session
        // intact (idempotent re-arm never passes through a cleared state).
        guard PmsetControl.setDisableSleep(true) else {
            let remaining = prior?.remaining(now: n) ?? 0
            lock.unlock()
            DaemonLog.write("SleepControlService: enable — pmset disablesleep 1 failed; prior session left intact")
            reply(false, DaemonEnableResult.internalError.rawValue, remaining)
            return
        }

        let deadline = n.addingTimeInterval(TimeInterval(durationSeconds))
        let accumulator = RequestValidation.accumulatorAfterGrant(
            durationSeconds: durationSeconds, now: n, priorState: prior)
        let state = SleepSessionState(
            deadline: deadline, startedAt: n,
            accumulatedActiveSeconds: accumulator, accumulatorUpdatedAt: n)

        // The persisted deadline is the cross-restart/reboot source of truth. If
        // it cannot be written, do NOT report an active session — reverse and
        // fail, so a relaunch/reboot won't lose a session it was told succeeded.
        guard SleepStateStore.write(state) else {
            // Roll back the pmset we just applied. If the rollback reversal also
            // fails, keep recovery ownership (persist a retry deadline + re-arm)
            // rather than orphaning SleepDisabled=on with no timer or state.
            if PmsetControl.setDisableSleep(false) {
                watchdog.cancel()
                DaemonLog.write("SleepControlService: enable — state write failed; rolled back, not armed")
            } else {
                armReversalRetryLocked(now: n)
                DaemonLog.write("SleepControlService: enable — state write AND rollback failed; retry armed")
            }
            lock.unlock()
            reply(false, DaemonEnableResult.internalError.rawValue, 0)
            return
        }
        watchdog.arm(deadline: deadline)
        let remaining = state.remaining(now: n)
        lock.unlock()

        DaemonLog.write("SleepControlService: enable ok — \(durationSeconds)s armed")
        reply(true, DaemonEnableResult.ok.rawValue, remaining)
    }

    func disable(reply: @escaping (Bool) -> Void) {
        lock.lock()
        let n = now()
        let ok = PmsetControl.setDisableSleep(false)
        if ok {
            watchdog.cancel()
            settleLocked(now: n)
        } else {
            // Reversal failed — do NOT cancel the watchdog or settle. Keep the
            // session active and re-arm a short retry so the daemon retains
            // ownership of recovery; otherwise SleepDisabled would be orphaned
            // ON with no timer, and the client would tear its UI down on the
            // next status read while sleep is still held.
            armReversalRetryLocked(now: n)
        }
        lock.unlock()
        DaemonLog.write("SleepControlService: disable — pmset 0 \(ok ? "ok; accumulator preserved" : "FAILED; retry armed")")
        reply(ok)
    }

    func status(reply: @escaping (Bool, Double) -> Void) {
        lock.lock()
        let n = now()
        let state = SleepStateStore.read()
        lock.unlock()
        if let state, state.isDeadlineTrustworthy(now: n), !state.isExpired(now: n) {
            reply(true, state.remaining(now: n))
        } else {
            reply(false, 0)
        }
    }

    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(drobuDaemonProtocolVersion)
    }

    func daemonVersion(reply: @escaping (String) -> Void) {
        reply(Self.daemonBuildVersion)
    }

    private static let daemonBuildVersion = "1.5"

    /// On a failed `pmset` reversal, re-arm the watchdog this far out to retry,
    /// keeping the daemon in charge of recovery instead of orphaning the state.
    private static let reversalRetryInterval: TimeInterval = 60

    // MARK: - Private (mutating; callers hold or acquire `lock`)

    /// Persist a "settled" state on stop/expiry: an already-past deadline (so
    /// status() reports inactive) carrying the *decayed* duty-cycle accumulator
    /// forward. This honors the documented invariant — the accumulator is NOT
    /// zeroed on stop, so a stop→start loop keeps accruing toward the cap
    /// instead of resetting it. (A daemon restart still clears via reconcile's
    /// expired cell, an accepted residual — re-arming the cap reset requires
    /// killing the root daemon, which the XPC peer gate does not grant.)
    private func settleLocked(now n: Date) {
        let carried = SleepStateStore.read()?.decayedAccumulatedSeconds(now: n) ?? 0
        let settled = SleepSessionState(
            deadline: n, startedAt: n,
            accumulatedActiveSeconds: carried, accumulatorUpdatedAt: n)
        SleepStateStore.write(settled)
    }

    /// Called when a `pmset disablesleep 0` reversal FAILED and the daemon must
    /// keep durable ownership of recovery. Persists a FUTURE-dated retry
    /// deadline — so `status()` reports the session active (truthful: sleep is
    /// still held) and boot reconciliation hits the future-deadline +
    /// SleepDisabled-on cell (re-arm), instead of reverseAndClear-ing an expired
    /// state and dropping the session — then arms the watchdog to retry.
    /// Best-effort: if the state write itself fails, the in-memory timer still
    /// retries, and a daemon restart falls back to the orphan-reverse path.
    private func armReversalRetryLocked(now n: Date) {
        let retryDeadline = n.addingTimeInterval(Self.reversalRetryInterval)
        let carried = SleepStateStore.read()?.decayedAccumulatedSeconds(now: n) ?? 0
        let retryState = SleepSessionState(
            deadline: retryDeadline, startedAt: n,
            accumulatedActiveSeconds: carried, accumulatorUpdatedAt: n)
        SleepStateStore.write(retryState)
        watchdog.arm(deadline: retryDeadline)
    }

    /// Watchdog fired — reverse + settle. The generation guard ignores a timer
    /// that fired just before a re-arm bumped the generation (a cancelled
    /// DispatchSource may still run an already-dispatched handler; without this
    /// guard that stale handler would reverse the freshly re-armed session).
    private func expire(firingGeneration: Int) {
        lock.lock()
        guard firingGeneration == watchdog.currentGeneration else {
            lock.unlock()
            return
        }
        let n = now()
        let ok = PmsetControl.setDisableSleep(false)
        if ok {
            watchdog.cancel()
            settleLocked(now: n)
        } else {
            // Reversal failed at the deadline — re-arm a short retry rather than
            // cancelling (which would orphan SleepDisabled=on permanently).
            armReversalRetryLocked(now: n)
        }
        lock.unlock()
        DaemonLog.write("SleepControlService: watchdog fired — pmset 0 \(ok ? "reversed" : "FAILED; retry armed")")
    }

    private func reconcileLocked() {
        let n = now()
        let state = SleepStateStore.read()
        let sleepDisabled = PmsetControl.isSleepDisabled()
        switch Reconciliation.decide(state: state, sleepDisabled: sleepDisabled, now: n) {
        case .reapplyDisableSleepAndArm(let deadline):
            _ = PmsetControl.setDisableSleep(true)
            watchdog.arm(deadline: deadline)
            DaemonLog.write("SleepControlService: reconcile — re-applied disablesleep + armed to persisted deadline")
        case .armWatchdogOnly(let deadline):
            watchdog.arm(deadline: deadline)
            DaemonLog.write("SleepControlService: reconcile — armed watchdog to persisted deadline")
        case .reverseAndClear:
            _ = PmsetControl.setDisableSleep(false)
            SleepStateStore.clear()
            DaemonLog.write("SleepControlService: reconcile — reversed orphaned/expired/untrusted disablesleep")
        case .noop:
            break
        }
    }
}
