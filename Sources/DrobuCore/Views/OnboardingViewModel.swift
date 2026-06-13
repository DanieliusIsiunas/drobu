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
        rows = Self.blueprint.compactMap { permission, tier, title, subtitle in
            let state = permissions.state(for: permission)
            guard state != .notApplicable else { return nil }
            return OnboardingRow(permission: permission, tier: tier,
                                 title: title, subtitle: subtitle, state: state)
        }
    }

    var requiredRows: [OnboardingRow] { rows.filter { $0.tier == .required } }
    var optionalRows: [OnboardingRow] { rows.filter { $0.tier == .optional } }

    /// True when every applicable required permission is granted or
    /// pending-restart. Optional rows never affect completion (never forced).
    var isComplete: Bool {
        permissions.requiredSatisfied(required: requiredRows.map(\.permission))
    }
}
