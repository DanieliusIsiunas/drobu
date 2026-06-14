import AppKit
import ApplicationServices
import CoreGraphics

/// The macOS permissions Drobu can request, surfaced by onboarding and the
/// Settings "Setup & Permissions" section.
enum Permission: CaseIterable, Hashable {
    case accessibility       // paste-anywhere (CGEvent Cmd+V)
    case screenRecording     // GIF + video capture
    case pasteboard          // clipboard capture; macOS 15.4+ only
    case closedLidHelper     // privileged daemon, approved in Login Items
    case launchAtLogin       // optional convenience

    /// True for permissions whose grant only takes effect after an app restart:
    /// the TCC check flips to "granted" immediately, but the functional API
    /// (CGEventTap for paste, the capture stream) doesn't actually work until
    /// the process relaunches. Modelling this is what lets onboarding show an
    /// honest "Restart to activate" instead of a false green check.
    var requiresRestart: Bool {
        switch self {
        case .accessibility, .screenRecording: return true
        case .pasteboard, .closedLidHelper, .launchAtLogin: return false
        }
    }
}

/// Live state of a single permission.
enum PermissionState: Equatable {
    case granted          // active and working now
    case pendingRestart   // granted this session, needs an app restart to take effect
    case notGranted       // not granted
    case notApplicable    // doesn't exist on this OS (e.g. pasteboard < macOS 15.4)
}

/// Completion of the *required* permission tier, with restart honesty baked in:
/// `.ready` only when every required permission works **now**; `.pendingRestart`
/// when the user has granted them all but at least one needs a relaunch to take
/// effect — so onboarding never claims "all set" while paste is still dead.
enum OnboardingCompletion: Equatable {
    case incomplete       // a required permission is still not granted
    case pendingRestart   // all required granted, but a restart is needed to activate
    case ready            // all required granted and working now
}

/// Injectable probe over the real OS permission checks, so `PermissionsService`'s
/// status mapping is unit-testable without touching TCC / SMAppService. Mirrors
/// `DaemonServiceControlling`. `@MainActor` because the production probe reaches
/// the main-actor `DaemonRegistrar` / `MainAppLaunchAgentControl`.
@MainActor
protocol PermissionProbing {
    /// `nil` means the permission does not exist on this OS (→ `.notApplicable`).
    func isGranted(_ permission: Permission) -> Bool?
}

/// Pure Screen Recording signal from a window-ownership snapshot. macOS 10.15+
/// gates *other apps'* window names (titles) behind Screen Recording permission:
/// without it, `kCGWindowName` for a foreign **normal** window is empty/absent.
/// So a visible foreign title proves we hold the permission.
///
/// CRITICAL: only count NORMAL app windows (`windowLayer == 0`). System chrome —
/// the menu bar, Dock, Window Server overlays — sits at higher layers and keeps
/// a readable title (e.g. Window Server's "Menubar") REGARDLESS of the grant.
/// Counting those is a false positive that greens the row for a process that
/// actually has no access (observed live on macOS 26, 2026-06-14: a process with
/// no grant still saw "Menubar", so the unfiltered check was always true).
func screenRecordingGrantedFromWindows(_ windows: [(ownerPID: pid_t, layer: Int, name: String?)],
                                       ourPID: pid_t) -> Bool {
    windows.contains { $0.layer == 0 && $0.ownerPID != ourPID && !($0.name ?? "").isEmpty }
}

/// Production probe wrapping the real platform APIs.
@MainActor
struct SystemPermissionProbe: PermissionProbing {
    // Cached once — the probe is polled repeatedly (launch baseline + every
    // live refresh × every row), so don't reconstruct these per call.
    private let daemonRegistrar = DaemonRegistrar()
    private let launchAgent = MainAppLaunchAgentControl()

    func isGranted(_ permission: Permission) -> Bool? {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            // CGPreflight has documented false-NEGATIVES on macOS 15 (returns
            // false even when granted — ScreenCaptureService.swift:37). Trust a
            // `true` reading (no false positives); otherwise fall back to the
            // window-name redaction signal — but ONLY normal app windows
            // (layer 0): system chrome like Window Server's "Menubar" keeps a
            // readable title without the grant and would false-green the row.
            if CGPreflightScreenCaptureAccess() { return true }
            return screenRecordingGrantedFromWindows(Self.onScreenWindowOwnership(),
                                                     ourPID: ProcessInfo.processInfo.processIdentifier)
        case .pasteboard:
            // macOS 15.4+ only; below that the selector is absent → notApplicable
            // (drobuAccessGranted returns nil). Reading never trips the alert.
            return NSPasteboard.general.drobuAccessGranted
        case .closedLidHelper:
            return daemonRegistrar.status == .enabled
        case .launchAtLogin:
            return launchAgent.isEnabled
        }
    }

    /// (ownerPID, windowLayer, window title) for on-screen, non-desktop windows.
    /// System boundary — kept out of the pure decision above so that stays
    /// testable. `CGWindowListCopyWindowInfo` needs no permission and never
    /// prompts; only the window *names* it returns are gated by Screen Recording.
    private static func onScreenWindowOwnership() -> [(ownerPID: pid_t, layer: Int, name: String?)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.map { window in
            (ownerPID: (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
             layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
             name: window[kCGWindowName as String] as? String)
        }
    }
}

/// Reports the live state of every Drobu permission, applying the restart-aware
/// rule. Captures a launch baseline at init so a restart-requiring permission
/// that was NOT granted at launch but is granted now reports `.pendingRestart`
/// (never a false `.granted`). Injectable probe → fully unit-testable.
@MainActor
final class PermissionsService {
    private let probe: PermissionProbing
    /// granted-at-launch snapshot per permission (not-applicable / unknown → false).
    private let grantedAtLaunch: [Permission: Bool]

    init(probe: PermissionProbing = SystemPermissionProbe()) {
        self.probe = probe
        var baseline: [Permission: Bool] = [:]
        for permission in Permission.allCases {
            baseline[permission] = probe.isGranted(permission) ?? false
        }
        self.grantedAtLaunch = baseline
    }

    func state(for permission: Permission) -> PermissionState {
        guard let grantedNow = probe.isGranted(permission) else { return .notApplicable }
        guard grantedNow else { return .notGranted }
        guard permission.requiresRestart else { return .granted }
        // Granted now AND restart-requiring: it works only if it was already
        // granted at launch; a grant made this session needs a relaunch.
        return (grantedAtLaunch[permission] ?? false) ? .granted : .pendingRestart
    }

    /// Restart-aware completion of a required set. `.ready` only when every
    /// required permission works now; `.pendingRestart` when all are
    /// granted-or-pending but at least one needs a relaunch to activate;
    /// `.incomplete` if any is not granted. `.notApplicable` counts as satisfied
    /// (the permission doesn't exist on this OS).
    func completion(required: [Permission]) -> OnboardingCompletion {
        var anyPending = false
        for permission in required {
            switch state(for: permission) {
            case .granted, .notApplicable: continue
            case .pendingRestart: anyPending = true
            case .notGranted: return .incomplete
            }
        }
        return anyPending ? .pendingRestart : .ready
    }

    /// True when every required permission is granted or pending-restart (the
    /// user has done their part — a restart is mechanical).
    func requiredSatisfied(required: [Permission]) -> Bool {
        completion(required: required) != .incomplete
    }
}
