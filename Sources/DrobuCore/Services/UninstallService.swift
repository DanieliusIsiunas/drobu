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
    var sessionReversal: UninstallStepOutcome
    var daemonStateTeardown: UninstallStepOutcome
    var daemonUnregister: UninstallStepOutcome
    var launchAtLoginUnregister: UninstallStepOutcome
    var dataErase: UninstallStepOutcome

    /// A registration step failed → orphaned residue the user can't see may
    /// remain. (A failed session reversal or data wipe is logged but does not
    /// drive the residual prompt — neither leaves an un-removable Login Item.)
    var hadRegistrationFailure: Bool {
        if case .failed = daemonUnregister { return true }
        if case .failed = launchAtLoginUnregister { return true }
        return false
    }

    /// User-facing summary shown before quit when a registration step failed.
    var residualSummary: String? {
        guard hadRegistrationFailure else { return nil }
        return "Drobu was removed, but a background item registration may remain. "
            + "Open System Settings → General → Login Items to remove it."
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

    init(daemon: DaemonControlling = DaemonClient(),
         registrar: DaemonRegistration = DaemonRegistrar(),
         launchAgent: LaunchAgentControlling = MainAppLaunchAgentControl(),
         dataEraser: DataErasing = DataEraser(),
         trasher: BundleTrashing = BundleTrasher(),
         bundleURL: URL = Bundle.main.bundleURL,
         terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.daemon = daemon
        self.registrar = registrar
        self.launchAgent = launchAgent
        self.dataEraser = dataEraser
        self.trasher = trasher
        self.bundleURL = bundleURL
        self.terminate = terminate
    }

    /// Run the teardown. Does NOT trash the bundle or quit — the caller shows any
    /// residual summary first, then calls `scheduleSelfDeleteAndQuit()`.
    @discardableResult
    func run(options: UninstallOptions) async -> UninstallResult {
        // Capture once: the unregister below changes this, and every daemon step
        // gates on whether there was a daemon to act on in the first place.
        let daemonRegistered = registrar.status == .enabled

        // 1. Reverse an active session FIRST (R14) so `pmset disablesleep` is not
        //    left applied with its reversal owner about to be removed.
        let sessionReversal: UninstallStepOutcome
        if daemonRegistered {
            sessionReversal = (await daemon.disable() == true)
                ? .ok : .failed("session reversal unconfirmed")
        } else {
            sessionReversal = .skipped
        }

        // 2. Best-effort root-state teardown (R3). An old daemon without the
        //    selector — or an unreachable one — returns nil → skipped, not failed.
        let daemonStateTeardown: UninstallStepOutcome
        if daemonRegistered {
            daemonStateTeardown = (await daemon.teardown() == true) ? .ok : .skipped
        } else {
            daemonStateTeardown = .skipped
        }

        // 3. Unregister the daemon (BTM terminates the running process).
        let daemonUnregister: UninstallStepOutcome
        if daemonRegistered {
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
