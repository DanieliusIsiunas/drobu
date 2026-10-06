import AppKit
import SwiftUI
@preconcurrency import VisionKit

/// Editor for still images (Cmd+Right edit mode for `kindImage`): crop plus
/// hand-drawn markup (highlight box with a comment, arrow, note).
///
/// A presentation of an `ImageEditSession`, which owns all edit state — so the same
/// edit can move between the inline preview pane and the Shift large preview.
/// Layers, bottom to top: an invisible first-responder key view (Esc, Cmd+Return,
/// 1–4, Delete, ⌘Z — the `GIFTrimPlayerView` pattern), the image, the markup layer,
/// and the crop corners. The large presentation uses the Live Text image view as its
/// base, interactive only while the Select text tool is active.
struct ImageCropView: View {
    enum Presentation {
        case inline, large
    }

    @Bindable var session: ImageEditSession
    let presentation: Presentation

    @State private var focus = EditorFocusHandle()

    var body: some View {
        VStack(spacing: 0) {
            if let cgImage = session.cgImage {
                ZStack {
                    // Invisible key handler in the background so it never blocks the overlay.
                    ImageCropKeyView(
                        focus: focus,
                        onSave: { session.save() },
                        onDiscard: { session.discard() },
                        onColorKey: { session.pick($0) },
                        onDeleteSelected: { session.deleteSelected() },
                        onUndo: { session.undoLast() }
                    )

                    baseImage(cgImage)

                    MarkupOverlayView(
                        annotations: $session.annotations,
                        selectedID: $session.selectedID,
                        tool: session.tool,
                        color: session.color,
                        metrics: session.metrics,
                        geometry: session.cropGeometry,
                        isInteractionEnabled: !session.isSaving,
                        focus: focus,
                        onRequestSave: { latest in session.save(annotations: latest) }
                    )

                    CropOverlayView(geometry: $session.cropGeometry, isInteractionEnabled: !session.isSaving)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

                infoBar
            } else {
                ProgressView("Loading image...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Backstop for the panel's own clamp: without Live Text here, Select
            // text would leave the image inert.
            if !offersSelectText, !session.tool.draws { session.tool = .box }
            session.load()
        }
    }

    /// Select text needs Live Text: only the large presentation has it, and only
    /// where VisionKit supports image analysis.
    private var offersSelectText: Bool {
        presentation == .large && ImageAnalyzer.isSupported
    }

    @ViewBuilder
    private func baseImage(_ cgImage: CGImage) -> some View {
        if presentation == .large, ImageAnalyzer.isSupported {
            LiveTextImageView(
                imageData: session.data,
                contentHash: session.contentHash,
                isInteractive: !session.tool.draws
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var infoBar: some View {
        HStack {
            if session.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                Spacer()
            } else {
                MarkupToolbar(
                    tools: offersSelectText ? MarkupTool.allCases : MarkupTool.drawingTools,
                    selectedTool: session.tool,
                    color: session.color,
                    // Restore focus FIRST: it commits an open label, which writes the
                    // overlay's annotation snapshot back — mutating state before that
                    // would be overwritten by the stale snapshot.
                    onTool: { tool in focus.restore(); session.tool = tool },
                    onColor: { swatch in focus.restore(); session.pick(swatch) }
                )
                Spacer(minLength: 8)
                Text("\u{2318}\u{21A9} save  esc discard  \u{21E7} " + (presentation == .large ? "smaller" : "larger"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

// MARK: - Invisible key handler

/// Transparent first-responder view hosting the image editor's keys: the shared
/// `EditorKeyNSView` contract (Esc / Cmd+Return) plus markup keys. Placed in the
/// ZStack background so it never intercepts crop-edge or drawing clicks.
struct ImageCropKeyView: NSViewRepresentable {
    let focus: EditorFocusHandle
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onColorKey: ((MarkupColor) -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onUndo: (() -> Void)?

    func makeNSView(context: Context) -> ImageEditorKeyNSView {
        let view = ImageEditorKeyNSView()
        apply(to: view)
        focus.keyView = view
        // Invisible utility view — not an accessibility element.
        view.setAccessibilityElement(false)

        // Acquire focus after layout (same pattern as GIFTrimPlayerView).
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: ImageEditorKeyNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ImageEditorKeyNSView) {
        view.onSave = onSave
        view.onDiscard = onDiscard
        view.onColorKey = onColorKey
        view.onDeleteSelected = onDeleteSelected
        view.onUndo = onUndo
    }
}

/// `EditorKeyNSView` plus the markup keys: 1–4 pick a colour, Delete/Backspace
/// removes the selected annotation, ⌘Z removes the last one.
final class ImageEditorKeyNSView: EditorKeyNSView {
    var onColorKey: ((MarkupColor) -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onUndo: (() -> Void)?

    // MARK: Key contract (single source of truth)

    private static func flags(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    /// The palette colour a bare digit key selects (1 = first swatch), if any.
    static func paletteColor(for event: NSEvent) -> MarkupColor? {
        let palette = MarkupColor.allCases
        guard flags(of: event).isEmpty,
              let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
              (1...palette.count).contains(digit) else { return nil }
        return palette[digit - 1]
    }

    /// Bare Delete (backspace, 51) or Forward Delete (117).
    static func isDeleteKey(_ event: NSEvent) -> Bool {
        flags(of: event).isEmpty && (event.keyCode == 51 || event.keyCode == 117)
    }

    static func isUndoKey(_ event: NSEvent) -> Bool {
        flags(of: event) == .command && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    /// Every key this editor handles, including the base save/discard contract.
    /// The large preview uses it to hand these keys back to the editor when Live
    /// Text has taken focus.
    static func ownsKey(_ event: NSEvent) -> Bool {
        isSaveKey(event)
            || isDiscardKey(event)
            || paletteColor(for: event) != nil
            || isDeleteKey(event)
            || isUndoKey(event)
    }

    override func keyDown(with event: NSEvent) {
        if let color = Self.paletteColor(for: event) {
            onColorKey?(color)
            return
        }
        if Self.isDeleteKey(event) {
            onDeleteSelected?()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘Z is a menu key equivalent (Edit › Undo), so it can be consumed before
    /// keyDown. Claim it only while this view has focus, so a label field keeps its
    /// own text undo.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isUndoKey(event), window?.firstResponder === self {
            onUndo?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
