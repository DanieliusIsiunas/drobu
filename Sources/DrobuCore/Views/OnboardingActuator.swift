import AppKit
import CoreGraphics
import SwiftUI

/// Performs an `OnboardingAction` against the real platform APIs. System
/// boundary (deep-links, CG/AX requests, daemon remediation, relaunch) — kept
/// thin and excluded from unit tests; the decision logic that produces these
/// actions lives in `OnboardingViewModel` (tested). Used by `SettingsPanel`'s
/// Set Up section.
@MainActor
struct OnboardingActuator {
    func perform(_ action: OnboardingAction) {
        switch action {
        case .openAccessibilitySettings:
            openSystemPrivacyPane("Privacy_Accessibility")
        case .openScreenRecordingSettings:
            // Add Drobu to the Screen Recording list first (so the toggle
            // exists in Settings), then deep-link — mirrors the capture services.
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            openSystemPrivacyPane("Privacy_ScreenCapture")
        case .openPasteboardSettings:
            // Prime first: on macOS 15.4+ System Settings lists an app under
            // Pasteboard only after it has attempted a programmatic read (which
            // surfaces the "Allow Paste" alert). The 0.5s monitor only reads on a
            // *change*, so a fresh-install user who hasn't copied yet would land
            // on a pane where Drobu isn't listed. One user-initiated read here
            // registers Drobu + surfaces the grant alert before we deep-link —
            // mirrors the Screen Recording CGRequest-before-deep-link priming.
            primePasteboardAccess()
            openSystemPrivacyPane("Privacy_Pasteboard")
        case .enableClosedLidHelper:
            // State-correct: .notFound registers first, only .requiresApproval deep-links.
            _ = DaemonRegistrar().remediate()
        case .toggleLaunchAtLogin(let enable):
            let agent = MainAppLaunchAgentControl()
            do {
                if enable { try agent.register() } else { try agent.unregister() }
            } catch {
                Log.error("OnboardingActuator: launch-at-login toggle failed: \(error)")
            }
        case .restart:
            relaunch()
        }
    }

    /// One deliberate, user-initiated pasteboard read to register Drobu in the
    /// macOS 15.4+ Pasteboard privacy list and surface the system access alert,
    /// so the subsequent Settings deep-link lands on a pane where Drobu is
    /// listed. User-initiated (one tap) — distinct from the passive 0.5s poll the
    /// onboarding gotcha forbids. A no-op for the user if access is already
    /// granted, and harmless on < 15.4 (the row is never shown there).
    private func primePasteboardAccess() {
        _ = NSPasteboard.general.string(forType: .string)
    }

    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
            // Only quit the current instance once the new one is actually
            // launching. If the relaunch fails (bundle moved, LaunchServices
            // error), terminating anyway would leave NO Drobu running — keep
            // this instance alive and log instead.
            let launched = app != nil && error == nil
            let errorDesc = error?.localizedDescription
            DispatchQueue.main.async {
                if launched {
                    NSApp.terminate(nil)
                } else {
                    Log.error("OnboardingActuator: relaunch failed, keeping current instance running: \(errorDesc ?? "unknown error")")
                }
            }
        }
    }
}
