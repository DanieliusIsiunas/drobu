import AppKit
import Foundation

/// What the uninstall confirmation collected from the user.
struct UninstallOptions: Equatable, Sendable {
    /// Opt-in: also wipe clipboard history, videos, logs, and settings.
    var deleteData: Bool
}

/// Per-step outcome. `skipped` means the step had nothing to do (e.g. the daemon
/// was never registered); `failed` carries a description for the residual summary.
enum UninstallStepOutcome: Equatable, Sendable {
    case ok
    case skipped
    case failed(String)
}

/// Structured result of an uninstall run, so the UI can surface partial failures
/// before the app quits.
struct UninstallResult: Equatable, Sendable {
    let sessionReversal: UninstallStepOutcome
    let daemonStateTeardown: UninstallStepOutcome
    let daemonUnregister: UninstallStepOutcome
    let launchAtLoginUnregister: UninstallStepOutcome
    let dataErase: UninstallStepOutcome

    /// A registration step failed → orphaned residue the user can't see may
    /// remain. (A failed session reversal or data wipe is logged but does not
    /// drive the residual prompt — neither leaves an un-removable Login Item.)
    var hadRegistrationFailure: Bool {
        if case .failed = daemonUnregister { return true }
        if case .failed = launchAtLoginUnregister { return true }
        return false
    }

    /// User-facing summary shown before quit when something needs the user's
    /// attention: an orphan-able registration that may remain, or an unconfirmed
    /// sleep-setting reversal (which can leave the Mac unable to sleep).
    var residualSummary: String? {
        var parts: [String] = []
        if hadRegistrationFailure {
            parts.append("a background item registration may remain — open System Settings → General → Login Items to remove it")
        }
        if case .failed = sessionReversal {
            parts.append("Drobu couldn't confirm your Mac's sleep setting was restored — if your Mac won't sleep, open Terminal and run: sudo pmset -a disablesleep 0")
        }
        if case .failed = dataErase {
            parts.append("the clipboard history and settings you chose to delete may not have been fully removed — you can delete the \"ClipboardHistory\" folder inside ~/Library/Application Support manually")
        }
        guard !parts.isEmpty else { return nil }
        return "Drobu was removed, but " + parts.joined(separator: "; and ") + "."
    }
}

/// Orchestrates the ordered, failure-tolerant in-app uninstall. Every collaborator
/// is an injectable seam so the ordering and continuation logic are unit-testable
/// without touching the real daemon, `SMAppService`, Keychain, disk, or Trash.
///
/// Order is load-bearing: reverse the session (R14) before removing the daemon,
/// and never reference any Keychain API here — the license/trial items are
/// preserved by design (R6), enforced by construction (no `LicenseStore` seam).
@MainActor
final class UninstallService {
    private let daemon: DaemonControlling
    private let registrar: DaemonRegistration
    private let launchAgent: LaunchAgentControlling
    private let dataEraser: DataErasing
    private let trasher: BundleTrashing
    private let bundleURL: URL
    private let terminate: () -> Void
    /// Upper bound on each daemon XPC call. The XPC error handler only fires on
    /// connection loss, not on a live-but-wedged daemon, so an unbounded await
    /// could freeze the Settings sheet forever — cap it.
    private let daemonCallTimeout: TimeInterval

    init(daemon: DaemonControlling = DaemonClient(),
         registrar: DaemonRegistration = DaemonRegistrar(),
         launchAgent: LaunchAgentControlling = MainAppLaunchAgentControl(),
         dataEraser: DataErasing = DataEraser(),
         trasher: BundleTrashing = BundleTrasher(),
         bundleURL: URL = Bundle.main.bundleURL,
         daemonCallTimeout: TimeInterval = 3.0,
         terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.daemon = daemon
        self.registrar = registrar
        self.launchAgent = launchAgent
        self.dataEraser = dataEraser
        self.trasher = trasher
        self.bundleURL = bundleURL
        self.daemonCallTimeout = daemonCallTimeout
        self.terminate = terminate
    }

    /// Run the teardown. Does NOT trash the bundle or quit — the caller shows any
    /// residual summary first, then calls `scheduleSelfDeleteAndQuit()`.
    @discardableResult
    func run(options: UninstallOptions) async -> UninstallResult {
        // Capture once: the unregister below changes this. A *running* daemon
        // (.enabled) may hold an active session and root state to erase; a
        // .requiresApproval daemon isn't running but still has a registration
        // RECORD that shows in Login Items and that the user cannot remove from
        // the UI — so `unregister()` must run for it too, even though disable and
        // teardown (which need a live daemon) do not.
        let daemonStatus = registrar.status
        let daemonRunning = daemonStatus == .enabled
        let hasRegistration = daemonStatus == .enabled || daemonStatus == .requiresApproval
        let daemon = self.daemon
        let timeout = daemonCallTimeout

        // 1. Reverse an active session FIRST (R14) so `pmset disablesleep` is not
        //    left applied with its reversal owner about to be removed. (The daemon
        //    teardown in step 2 also reverses pmset defensively, in case this
        //    reply is lost.) The bounded (semaphore) calls run off the main actor:
        //    they genuinely return after the timeout even if a wedged daemon never
        //    replies — a structured-concurrency timeout can't, since the XPC
        //    continuation isn't cancellable — and they don't block the main thread.
        let sessionReversal: UninstallStepOutcome
        if daemonRunning {
            let reversed = await Task.detached { daemon.disableBounded(timeout: timeout) }.value
            sessionReversal = reversed ? .ok : .failed("session reversal unconfirmed")
        } else {
            sessionReversal = .skipped
        }

        // 2. Best-effort root-state teardown (R3). An old daemon without the
        //    selector — or an unreachable/wedged one — returns false → skipped.
        let daemonStateTeardown: UninstallStepOutcome
        if daemonRunning {
            let toreDown = await Task.detached { daemon.teardownBounded(timeout: timeout) }.value
            daemonStateTeardown = toreDown ? .ok : .skipped
        } else {
            daemonStateTeardown = .skipped
        }

        // 3. Unregister the daemon (BTM terminates a running process; for
        //    .requiresApproval it removes the orphan-able registration record).
        let daemonUnregister: UninstallStepOutcome
        if hasRegistration {
            if case .failed(let message) = registrar.unregister() {
                daemonUnregister = .failed(message)
            } else {
                daemonUnregister = .ok
            }
        } else {
            daemonUnregister = .skipped
        }

        // 4. Drop the cached XPC connection — it was built against the now-gone
        //    daemon instance and does not recover after unregister.
        daemon.resetConnection()

        // 5. Unregister launch-at-login. A login item that was never enabled is
        //    success (nothing to remove), not a failure.
        let launchAtLoginUnregister: UninstallStepOutcome
        if launchAgent.isEnabled {
            do {
                try launchAgent.unregister()
                launchAtLoginUnregister = .ok
            } catch {
                launchAtLoginUnregister = launchAgent.isEnabled
                    ? .failed(error.localizedDescription) : .ok
            }
        } else {
            launchAtLoginUnregister = .skipped
        }

        // 6. Optional data wipe (opt-in; never touches the Keychain).
        let dataErase: UninstallStepOutcome
        if options.deleteData {
            do {
                try dataEraser.eraseAllUserData()
                dataErase = .ok
            } catch {
                dataErase = .failed(error.localizedDescription)
            }
        } else {
            dataErase = .skipped
        }

        let result = UninstallResult(
            sessionReversal: sessionReversal,
            daemonStateTeardown: daemonStateTeardown,
            daemonUnregister: daemonUnregister,
            launchAtLoginUnregister: launchAtLoginUnregister,
            dataErase: dataErase)
        Log.info("UninstallService: run complete — \(result)")
        return result
    }

    /// Schedule the bundle self-delete (the trasher waits for the app + daemon to
    /// exit) and quit. Always the final action, so it cannot strand a live daemon.
    func scheduleSelfDeleteAndQuit() {
        trasher.scheduleTrash(bundleURL: bundleURL)
        terminate()
    }
}
