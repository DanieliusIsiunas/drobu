import SwiftUI

/// Subtle hover highlight for inline text buttons (`Text` + `.onTapGesture`),
/// matching the sidebar rows: a rounded fill appears under the cursor so the
/// clickable area is obvious before the click. Background-only (no `NSCursor`
/// push/pop, which is bug-prone to unbalance). Apply it BEFORE the site's
/// `.onTapGesture` so the tap and the hover share the same padded hit area.
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Drop-in hover highlight for inline text buttons. Place before
    /// `.onTapGesture` so the tap target matches the highlighted area.
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
