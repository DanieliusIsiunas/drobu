import AppKit
import SwiftUI

/// Inline editor for still images (Cmd+Right edit mode for `kindImage`): crop plus
/// hand-drawn markup (highlight box with a comment, arrow, note).
///
/// Mirrors `GIFTrimView`'s layout: the image fills the available space aspect-fit,
/// `MarkupOverlayView` takes drawing gestures, `CropOverlayView` draws the draggable
/// crop corners on top, and an info bar at the bottom holds the tools, colours, and
/// save/discard hints (plus saving / error states). Esc, Cmd+Return, 1–4, Delete and
/// ⌘Z are owned by an invisible first-responder NSView (the same pattern as
/// `GIFTrimPlayerView`) so keyboard handling matches the trim editors.
///
/// Save routing: with no markup, crop-only replaces the item in place (`onSave`), as
/// before; with markup, the flattened result becomes a NEW item (`onSaveAsNew`) and
/// the original screenshot is kept.
struct ImageCropView: View {
    let data: Data
    let onSave: (Data) -> Void
    let onSaveAsNew: (Data) -> Void
    let onDiscard: () -> Void

    @State private var cgImage: CGImage?
    @State private var cropGeometry = CropGeometry(contentWidth: 0, contentHeight: 0)
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var annotations: [MarkupAnnotation] = []
    @State private var selectedID: UUID?
    @State private var tool: MarkupTool = .box
    @State private var color: MarkupColor = MarkupDefaults.loadColor()
    @State private var metrics = MarkupMetrics(densityScale: 1)
    @State private var focus = EditorFocusHandle()

    var body: some View {
        VStack(spacing: 0) {
            if let cgImage {
                ZStack {
                    // Invisible key handler in the background so it never blocks the overlay.
                    ImageCropKeyView(
                        focus: focus,
                        onSave: { save() },
                        onDiscard: { discard() },
                        onColorKey: { pick($0) },
                        onDeleteSelected: { deleteSelected() },
                        onUndo: { undoLast() }
                    )

                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    MarkupOverlayView(
                        annotations: $annotations,
                        selectedID: $selectedID,
                        tool: tool,
                        color: color,
                        metrics: metrics,
                        geometry: cropGeometry,
                        isInteractionEnabled: !isSaving,
                        focus: focus,
                        onRequestSave: { latest in save(annotations: latest) }
                    )

                    CropOverlayView(geometry: $cropGeometry, isInteractionEnabled: !isSaving)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

                cropInfoBar
            } else {
                ProgressView("Loading image...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: decodeIfNeeded)
    }

    private var cropInfoBar: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                markupControls
                Spacer(minLength: 8)
                Text("\u{2318}\u{21A9} save  esc discard")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }

            if isSaving || errorMessage != nil { Spacer() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Tool picker + colour swatches. Plain views with tap gestures (not Buttons) so
    /// a click never moves keyboard focus off the editor's key view.
    private var markupControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MarkupTool.allCases, id: \.self) { candidate in
                    Image(systemName: Self.symbol(for: candidate))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(candidate == tool ? Color.primary.opacity(0.18) : .clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { focus.restore(); tool = candidate }
                        .help(candidate.accessibilityName)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(candidate.accessibilityName)
                        .accessibilityAddTraits(candidate == tool ? [.isButton, .isSelected] : .isButton)
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
                        // Restore focus FIRST: it commits an open label, which writes
                        // the overlay's annotation snapshot back — recolouring before
                        // that would be overwritten by the stale snapshot.
                        .onTapGesture { focus.restore(); pick(swatch) }
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
        case .box: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .note: return "text.bubble"
        }
    }

    // MARK: - Markup actions

    private func pick(_ newColor: MarkupColor) {
        color = newColor
        MarkupDefaults.saveColor(newColor)
        // Recolour the selection — only ever a deliberately clicked annotation;
        // newly drawn shapes are never auto-selected.
        if let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].color = newColor
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    private func undoLast() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        if removed.id == selectedID { selectedID = nil }
    }

    private func decodeIfNeeded() {
        guard cgImage == nil else { return }
        let imageData = data
        Task {
            // Decode off the main actor — a large Retina screenshot can take hundreds
            // of milliseconds to decode, and the gate (isBitmapData) is header-only.
            let (decoded, fileDensity) = await Task.detached {
                (ImageCrop.decodeBitmap(from: imageData), ImageCrop.pixelDensityScale(of: imageData))
            }.value

            // Header-valid but undecodable (e.g., truncated PNG): exit edit mode
            // instead of stranding the user on a spinner with no key handler.
            guard let decoded else {
                Log.error("ImageCropView: bitmap decode failed — exiting edit mode")
                onDiscard()
                return
            }
            cgImage = decoded
            // Most pasteboard images report 72 DPI even when captured on Retina, so
            // an unknown density falls back to this display's scale (screenshots are
            // nearly always taken on the Mac they're edited on).
            let density = fileDensity ?? NSScreen.main?.backingScaleFactor ?? 2
            metrics = MarkupMetrics(densityScale: density)
            // Initialise crop state from the TRUE pixel size (never NSImage.size, which
            // is in points and under-reports Retina media).
            cropGeometry = CropGeometry(contentWidth: decoded.width, contentHeight: decoded.height)
        }
    }

    private func discard() {
        guard !isSaving else { return }
        onDiscard()
    }

    private func save(annotations latest: [MarkupAnnotation]? = nil) {
        guard !isSaving, let cgImage else { return }
        let markup = latest ?? annotations

        if !markup.isEmpty {
            saveAnnotated(cgImage, markup)
            return
        }

        // Untouched crop → behave exactly like Esc: close, record untouched, no message.
        guard !cropGeometry.isFullFrame else {
            onDiscard()
            return
        }

        isSaving = true
        errorMessage = nil
        let rect = cropGeometry.cropRect

        Task.detached {
            let pngData = ImageCrop.cropAndEncodePNG(cgImage, to: rect)
            await MainActor.run {
                if let pngData {
                    onSave(pngData)
                } else {
                    Log.error("ImageCropView: crop/PNG encode failed")
                    isSaving = false
                    errorMessage = "Save failed — try again"
                }
            }
        }
    }
}

extension ImageCropView {
    /// Flatten markup onto the full image, crop, encode — off the main actor — and
    /// hand the PNG over as a new history item.
    private func saveAnnotated(_ image: CGImage, _ markup: [MarkupAnnotation]) {
        isSaving = true
        errorMessage = nil
        let rect = cropGeometry.cropRect
        let metrics = metrics

        Task.detached {
            let pngData = MarkupRenderer.renderPNG(image: image, annotations: markup, crop: rect, metrics: metrics)
            await MainActor.run {
                if let pngData {
                    onSaveAsNew(pngData)
                } else {
                    Log.error("ImageCropView: markup render/PNG encode failed")
                    isSaving = false
                    errorMessage = "Save failed — try again"
                }
            }
        }
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

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let palette = MarkupColor.allCases
        if flags.isEmpty, let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...palette.count).contains(digit) {
            onColorKey?(palette[digit - 1])
            return
        }
        // 51 = Delete (backspace), 117 = Forward Delete.
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelected?()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘Z is a menu key equivalent (Edit › Undo), so it can be consumed before
    /// keyDown. Claim it only while this view has focus, so a label field keeps its
    /// own text undo.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z",
           window?.firstResponder === self {
            onUndo?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
