import Foundation

/// Which sleep-prevention mode (if any) the status item should reflect.
/// Precedence (Closed Lid over Keep Awake) is resolved by the caller before
/// constructing this value — see `AppDelegate.refreshStatusIcon()`.
public enum SleepMode: Equatable, Sendable {
    case none
    case keepAwake
    case closedLid
}

/// Color of the bottom-right sleep dot on the menu-bar icon.
/// AppKit-free so the indicator decision stays unit-testable; AppDelegate maps
/// these to `NSColor` at the rendering boundary.
public enum SleepDotColor: Equatable, Sendable {
    case green   // Keep Awake
    case orange  // Closed Lid
}

/// The full set of overlays the menu-bar icon should show. The sleep dot
/// (bottom-right) and the update arrow (top-right) are independent — both can
/// be present at once — which is exactly the coexistence rule under test.
public struct StatusIconIndicators: Equatable, Sendable {
    public let sleepDot: SleepDotColor?
    public let showsUpdateArrow: Bool

    public init(sleepDot: SleepDotColor?, showsUpdateArrow: Bool) {
        self.sleepDot = sleepDot
        self.showsUpdateArrow = showsUpdateArrow
    }
}

/// Pure presentation logic for the menu-bar status item: the gentle-update
/// menu-item title, the icon overlays (sleep dot + update arrow coexistence),
/// and the status button's VoiceOver label. No AppKit, no Sparkle — so it is
/// fully testable. Owns both the sleep-mode and update-pending inputs because
/// the icon-coexistence decision spans both.
public enum StatusItemPresentation {
    /// Title for the disabled, informational "update available" menu item.
    /// `version` is Sparkle's `displayVersionString` (already human-readable);
    /// this only formats it. Tolerates an already-`v`-prefixed string and an
    /// empty/whitespace version (drops the version segment rather than showing
    /// a bare "v").
    public static func menuItemTitle(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Update available" }
        let normalized = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        guard !normalized.isEmpty else { return "Update available" }
        return "Update available — v\(normalized)"
    }

    /// The coexistence rule: the sleep dot reflects the active sleep mode, and
    /// the update arrow shows iff an update is pending — independently. When
    /// both hold, both indicators are present.
    public static func statusIconIndicators(
        sleepMode: SleepMode,
        updatePending: Bool
    ) -> StatusIconIndicators {
        let dot: SleepDotColor?
        switch sleepMode {
        case .none: dot = nil
        case .keepAwake: dot = .green
        case .closedLid: dot = .orange
        }
        return StatusIconIndicators(sleepDot: dot, showsUpdateArrow: updatePending)
    }

    /// VoiceOver label for the status-item button. Surfaces a pending update so
    /// the icon's new arrow glyph is announced, not silent.
    public static func statusButtonAccessibilityLabel(updatePending: Bool) -> String {
        updatePending ? "Drobu — update available" : "Drobu"
    }
}
