import SwiftUI

/// Visual role for the Settings action/status pills (v1.9.5 polish). The Settings
/// panel is translucent, so a bare colored `Text` action loses contrast on a light
/// wallpaper; an always-on tinted **capsule** carries its own contrast on any
/// background. Red is reserved for destructive actions (Delete / Uninstall /
/// Remove helper) and nothing else — neutral safe actions read as calm grey;
/// status uses semantic green / amber. Shared by `SettingsView` and the Set Up
/// pane (`OnboardingView`) so every action across the window reads the same.
enum SettingsPillRole {
    case neutral, destructive, success, warning

    /// Text (and leading-dot) color.
    var foreground: Color {
        switch self {
        case .neutral: return .primary
        case .destructive: return .red
        case .success: return .green
        case .warning: return .orange
        }
    }

    /// Capsule fill — the same hue at a fixed opacity, lifting the text well clear
    /// of the translucent material so it reads on any wallpaper. Hover brightens it.
    func fill(hovering: Bool) -> Color {
        foreground.opacity(hovering ? 0.37 : 0.30)
    }
}

/// Always-on tinted pill for an inline settings action. Hover brightens the fill;
/// the padded capsule is the hit area (apply before `.onTapGesture`, mirroring the
/// old `hoverHighlight`). `enabled: false` mutes it for a disabled action.
struct ActionPill: ViewModifier {
    let role: SettingsPillRole
    var enabled: Bool = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? role.foreground : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(enabled ? role.fill(hovering: hovering) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
            .onHover { if enabled { hovering = $0 } }
            .animation(.easeInOut(duration: 0.12), value: hovering)
            // Self-contained disabled contract: a muted pill ignores hits, so a
            // disabled action can't fire even if a call site forgets to guard its
            // tap. Enabled pills get the default (true) — no behavior change.
            .allowsHitTesting(enabled)
    }
}

extension View {
    /// Render an inline `Text` action as a tinted pill. See `ActionPill`.
    func actionPill(_ role: SettingsPillRole, enabled: Bool = true) -> some View {
        modifier(ActionPill(role: role, enabled: enabled))
    }
}
