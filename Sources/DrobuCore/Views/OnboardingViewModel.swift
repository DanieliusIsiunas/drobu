import Combine
import Foundation

enum OnboardingTier: Equatable {
    case required
    case optional
}

/// What a row's control does given its current state. The view-model produces
/// these; the panel layer performs them against the real APIs (system boundary).
enum OnboardingAction: Equatable {
    case openAccessibilitySettings
    case openScreenRecordingSettings
    case openPasteboardSettings
    case enableClosedLidHelper
    case toggleLaunchAtLogin(enable: Bool)
    case restart
}

/// Whether dispatching `action` should mark first-run onboarding complete.
/// Only a restart that actually finishes required setup counts: a row-level
/// "Restart to activate" can fire while `completion` is still `.incomplete`
/// (e.g. Accessibility granted this session but Pasteboard still denied) — that
/// must NOT suppress auto-onboarding before the user finishes the rest. Pure so
/// the rule is unit-tested even though the call site is the (untested) panel.
func onboardingCompletesGate(on action: OnboardingAction, completion: OnboardingCompletion) -> Bool {
    action == .restart && completion != .incomplete
}

/// One permission row in the onboarding checklist.
struct OnboardingRow: Identifiable, Equatable {
    let permission: Permission
    let tier: OnboardingTier
    let title: String
    let subtitle: String
    let state: PermissionState
    var id: Permission { permission }

    /// The action the row's control performs given its state, or nil when there
    /// is nothing to do (granted, or not applicable). Restart-requiring
    /// permissions route to `.restart` once granted-but-pending.
    var primaryAction: OnboardingAction? {
        switch (permission, state) {
        // Launch-at-login is a toggle, not a one-way grant: it always offers the
        // flip (turn off when on, on when off) — matched before the granted catch.
        case (.launchAtLogin, _):
            return .toggleLaunchAtLogin(enable: state != .granted)
        case (_, .granted), (_, .notApplicable):
            return nil
        case (.accessibility, .pendingRestart), (.screenRecording, .pendingRestart):
            return .restart
        case (.accessibility, _):
            return .openAccessibilitySettings
        case (.screenRecording, _):
            return .openScreenRecordingSettings
        case (.pasteboard, _):
            return .openPasteboardSettings
        case (.closedLidHelper, _):
            return .enableClosedLidHelper
        }
    }
}

/// Turns live permission state into the tiered, ordered rows the onboarding UI
/// renders, plus the completion gate. Pure logic over `PermissionsService` —
/// separated from SwiftUI so it is unit-testable with a mock probe.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var rows: [OnboardingRow] = []
    /// Completion recomputed in `refresh()` in the same synchronous pass that
    /// builds the rows, so the footer never disagrees with the rows on screen.
    /// Tri-state so we never claim "all set" while a required permission is only
    /// pending a restart (it offers "Restart to activate" instead).
    @Published private(set) var completion: OnboardingCompletion = .incomplete

    /// The user has done their part (granted everything required — a restart, if
    /// any, is mechanical). Distinct from "ready to use right now" (`.ready`).
    var isComplete: Bool { completion != .incomplete }
    private let permissions: PermissionsService

    /// Ordered blueprint: permission, tier, title, benefit-first subtitle.
    /// Pasteboard is required but only when applicable on this OS — a row whose
    /// state resolves to `.notApplicable` (pasteboard < macOS 15.4) is dropped.
    private static let blueprint: [(Permission, OnboardingTier, String, String)] = [
        (.accessibility, .required, "Paste anywhere",
         "Lets Drobu paste into any app when you press your hotkey. Without it, items still copy — you just paste them yourself."),
        (.pasteboard, .required, "Clipboard access",
         "So Drobu can see what you copy and keep your history."),
        (.screenRecording, .optional, "GIF & screen capture",
         "For recording GIFs and clips. Drobu only reads your own screen — nothing leaves your Mac."),
        (.closedLidHelper, .optional, "Closed-lid keep-awake",
         "Keeps your Mac awake with the lid shut. Approved once in Login Items."),
        (.launchAtLogin, .optional, "Launch at login",
         "Have Drobu waiting in your menu bar every time you log in."),
    ]

    init(permissions: PermissionsService) {
        self.permissions = permissions
        refresh()
    }

    /// Re-poll every permission and rebuild the rows. Called on the panel's
    /// focus re-check and timer so rows flip live as the user grants each one.
    func refresh() {
        let newRows: [OnboardingRow] = Self.blueprint.compactMap { permission, tier, title, subtitle in
            let state = permissions.state(for: permission)
            guard state != .notApplicable else { return nil }
            return OnboardingRow(permission: permission, tier: tier,
                                 title: title, subtitle: subtitle, state: state)
        }
        rows = newRows
        // Restart-aware completion over the required tier. Optional rows never
        // affect it — nothing is forced. Computed here, in the same synchronous
        // pass that built the rows, so the footer can't drift from what's on screen.
        let requiredPerms = newRows.filter { $0.tier == .required }.map(\.permission)
        completion = permissions.completion(required: requiredPerms)
    }

    var requiredRows: [OnboardingRow] { rows.filter { $0.tier == .required } }
    var optionalRows: [OnboardingRow] { rows.filter { $0.tier == .optional } }
}
