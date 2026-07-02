import SwiftUI

/// Visual role for the Settings action/status pills. The Settings panel is translucent
/// (`.regularMaterial`), so a *tinted* (translucent) fill composites with the wallpaper
/// and the label's contrast becomes wallpaper-dependent: red text on a translucent-red
/// fill reads on a dark wallpaper but collapses to unreadable red-on-pale-pink on a light
/// one. The fix is the standard danger/status treatment — an **opaque** saturated fill
/// paired with a **fixed** high-contrast label — so contrast is independent of whatever is
/// behind the pill (this is Material's error/on-error, GitHub Primer's Danger button, and
/// Apple's prominent-button convention; an opaque surface removes the background from the
/// contrast equation, no runtime luminance guessing). The saturated roles share one muted,
/// deep, dark register (brick red / forest green / amber-bronze) so they read as a single
/// palette, and all take a white label. Neutral stays a calm **translucent adaptive grey**
/// — its `.primary` label reads on either appearance,
/// so it needs no opaque fill. Shared by `SettingsView` (actionLink + statusPill) and the
/// Set Up pane (`OnboardingView`) so every action across the window reads the same.
enum SettingsPillRole {
    case neutral, destructive, success, warning

    /// Label (and status-dot) color, fixed to clear contrast against `fill`.
    var foreground: Color {
        switch self {
        case .neutral:                         return .primary  // adaptive; pairs with the grey tint
        case .destructive, .success, .warning: return .white    // on the deep, dark, muted fills
        }
    }

    /// Capsule fill. Neutral is a translucent adaptive grey (calm, readable on either
    /// appearance); the saturated roles are OPAQUE so their fixed label clears contrast on
    /// any background. Hover deepens the fill. Contrast (white label vs fill): red ~7:1,
    /// green ~6:1, amber-bronze ~5.6:1 — all clear WCAG 1.4.3 for the 12pt-semibold text.
    func fill(hovering: Bool) -> Color {
        switch self {
        case .neutral:
            return Color.primary.opacity(hovering ? 0.37 : 0.30)
        case .destructive:  // deep MUTED brick red — readable with white but calmer/less
                            // vivid than a bright alert red (Primer #CB2431 read too loud)
            return hovering ? Color(red: 0.54, green: 0.15, blue: 0.17)
                            : Color(red: 0.64, green: 0.18, blue: 0.20)
        case .success:      // deep muted forest green — matches the brick red's register
            return hovering ? Color(red: 0.15, green: 0.37, blue: 0.22)
                            : Color(red: 0.19, green: 0.44, blue: 0.27)
        case .warning:      // deep muted amber/bronze — dark enough for a white label, so it sits
                            // as a dark chip beside red/green (a light amber would break the set)
            return hovering ? Color(red: 0.47, green: 0.33, blue: 0.09)
                            : Color(red: 0.55, green: 0.39, blue: 0.11)
        }
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
