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
        watchdog = Watchdog(queue: watchdogQueue) { [weak self] in
            self?.expire()
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
            DaemonLog.write("enable rejected (code \(rejection.enableResult.rawValue)) for \(durationSeconds)s")
            reply(false, rejection.enableResult.rawValue, 0)
            return
        }

        // Transactional: apply pmset first; on failure leave any prior session
        // intact (idempotent re-arm never passes through a cleared state).
        guard PmsetControl.setDisableSleep(true) else {
            let remaining = prior?.remaining(now: n) ?? 0
            lock.unlock()
            DaemonLog.write("enable: pmset disablesleep 1 failed; prior session left intact")
            reply(false, DaemonEnableResult.internalError.rawValue, remaining)
            return
        }

        let deadline = n.addingTimeInterval(TimeInterval(durationSeconds))
        let accumulator = RequestValidation.accumulatorAfterGrant(
            durationSeconds: durationSeconds, now: n, priorState: prior)
        let state = SleepSessionState(
            deadline: deadline, startedAt: n,
            accumulatedActiveSeconds: accumulator, accumulatorUpdatedAt: n)
        SleepStateStore.write(state)
        watchdog.arm(deadline: deadline)
        let remaining = state.remaining(now: n)
        lock.unlock()

        DaemonLog.write("enable ok: \(durationSeconds)s armed")
        reply(true, DaemonEnableResult.ok.rawValue, remaining)
    }

    func disable(reply: @escaping (Bool) -> Void) {
        lock.lock()
        let ok = PmsetControl.setDisableSleep(false)
        watchdog.cancel()
        SleepStateStore.clear()
        lock.unlock()
        DaemonLog.write("disable: pmset 0 \(ok ? "ok" : "FAILED"); state cleared")
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

    // MARK: - Private (mutating; callers hold or acquire `lock`)

    /// Watchdog fired — reverse + clear. Idempotent against a concurrent
    /// `disable` (a cancelled DispatchSource may still run an already-fired
    /// handler; reversing an already-disabled session is harmless).
    private func expire() {
        lock.lock()
        _ = PmsetControl.setDisableSleep(false)
        watchdog.cancel()
        SleepStateStore.clear()
        lock.unlock()
        DaemonLog.write("watchdog fired: session expired, disablesleep reversed")
    }

    private func reconcileLocked() {
        let n = now()
        let state = SleepStateStore.read()
        let sleepDisabled = PmsetControl.isSleepDisabled()
        switch Reconciliation.decide(state: state, sleepDisabled: sleepDisabled, now: n) {
        case .reapplyDisableSleepAndArm(let deadline):
            _ = PmsetControl.setDisableSleep(true)
            watchdog.arm(deadline: deadline)
            DaemonLog.write("reconcile: re-applied disablesleep + armed to persisted deadline")
        case .armWatchdogOnly(let deadline):
            watchdog.arm(deadline: deadline)
            DaemonLog.write("reconcile: armed watchdog to persisted deadline")
        case .reverseAndClear:
            _ = PmsetControl.setDisableSleep(false)
            SleepStateStore.clear()
            DaemonLog.write("reconcile: reversed orphaned/expired/untrusted disablesleep")
        case .noop:
            break
        }
    }
}
