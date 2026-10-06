import SwiftUI

/// Tool picker + colour swatches, shared by the inline editor and the large preview.
/// Plain views with tap gestures (not Buttons) so a click never moves keyboard focus
/// off the editor's key view. Callers that host an open label field must commit it
/// (restore focus) before mutating state — see `.claude/rules/media-editing-gotchas.md`.
struct MarkupToolbar: View {
    let tools: [MarkupTool]
    let selectedTool: MarkupTool
    let color: MarkupColor
    let onTool: (MarkupTool) -> Void
    let onColor: (MarkupColor) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(tools, id: \.self) { candidate in
                    Image(systemName: Self.symbol(for: candidate))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(candidate == selectedTool ? Color.primary.opacity(0.18) : .clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onTool(candidate) }
                        .help(candidate.accessibilityName)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(candidate.accessibilityName)
                        .accessibilityAddTraits(candidate == selectedTool ? [.isButton, .isSelected] : .isButton)
                }
            }

            HStack(spacing: 6) {
                ForEach(MarkupColor.allCases, id: \.self) { swatch in
                    Circle()
                        .fill(Color(cgColor: swatch.cgColor()))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(swatch == color ? 0.9 : 0), lineWidth: 2)
                                .padding(-3)
                        )
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture { onColor(swatch) }
                        .help("\(swatch.accessibilityName) (\(swatch.keyNumber))")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(swatch.accessibilityName) colour")
                        .accessibilityHint("Press \(swatch.keyNumber)")
                        .accessibilityAddTraits(swatch == color ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private static func symbol(for tool: MarkupTool) -> String {
        switch tool {
        case .select: return "character.cursor.ibeam"
        case .box: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .note: return "text.bubble"
        }
    }
}
