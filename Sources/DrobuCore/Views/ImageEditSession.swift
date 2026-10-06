import AppKit
import Observation

/// One image edit (crop + markup) that outlives whichever surface shows it.
///
/// `PanelView` creates a session when ⌘→ (or a drawing tool in the large preview)
/// starts editing an image, and hands it to the inline pane or the Shift large
/// preview — only one of them shows the editor at a time. Because the state lives
/// here instead of in a view's `@State`, moving the editor between the two surfaces
/// keeps the shapes, crop, selection, tool, and colour.
///
/// Save routing: with markup, the flattened result becomes a NEW item
/// (`onSaveAsNew`) and the original is kept; crop-only replaces in place
/// (`onSave`); untouched behaves like Esc (`onDiscard`).
@MainActor
@Observable
final class ImageEditSession {
    let data: Data
    let contentHash: String

    private(set) var cgImage: CGImage?
    var cropGeometry = CropGeometry(contentWidth: 0, contentHeight: 0)
    var annotations: [MarkupAnnotation] = []
    var selectedID: UUID?
    var tool: MarkupTool = .box
    private(set) var color: MarkupColor
    private(set) var metrics = MarkupMetrics(densityScale: 1)
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored var onSave: (Data) -> Void = { _ in }
    @ObservationIgnored var onSaveAsNew: (Data) -> Void = { _ in }
    @ObservationIgnored var onDiscard: () -> Void = {}

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fallbackDensity: () -> CGFloat
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// `fallbackDensity` is used when the image reports no density above 72 DPI —
    /// most pasteboard images do, even Retina captures — so it defaults to this
    /// display's scale (screenshots are nearly always edited on the Mac that took them).
    init(
        data: Data,
        contentHash: String,
        defaults: UserDefaults = .standard,
        fallbackDensity: @escaping () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 2 }
    ) {
        self.data = data
        self.contentHash = contentHash
        self.defaults = defaults
        self.fallbackDensity = fallbackDensity
        self.color = MarkupDefaults.loadColor(from: defaults)
    }

    // MARK: - Loading

    /// Decode once, off the main actor. Idempotent: both surfaces may ask.
    /// A header-valid but undecodable image (e.g. truncated PNG) exits edit mode
    /// instead of stranding the user on a spinner.
    @discardableResult
    func load() -> Task<Void, Never> {
        if let loadTask { return loadTask }
        let imageData = data
        let task = Task { [weak self] in
            let (decoded, fileDensity) = await Task.detached {
                (ImageCrop.decodeBitmap(from: imageData), ImageCrop.pixelDensityScale(of: imageData))
            }.value
            guard let self else { return }
            guard let decoded else {
                Log.error("ImageEditSession: bitmap decode failed — exiting edit mode")
                self.onDiscard()
                return
            }
            self.metrics = MarkupMetrics(
                densityScale: fileDensity ?? self.fallbackDensity(),
                contentSize: CGSize(width: decoded.width, height: decoded.height)
            )
            // Crop state from the TRUE pixel size (never NSImage.size, which is in
            // points and under-reports Retina media).
            self.cropGeometry = CropGeometry(contentWidth: decoded.width, contentHeight: decoded.height)
            self.cgImage = decoded
        }
        loadTask = task
        return task
    }

    // MARK: - Markup actions

    func pick(_ newColor: MarkupColor) {
        color = newColor
        MarkupDefaults.saveColor(newColor, to: defaults)
        // Recolour the selection — only ever a deliberately clicked annotation;
        // newly drawn shapes are never auto-selected.
        if let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].color = newColor
        }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func undoLast() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        if removed.id == selectedID { selectedID = nil }
    }

    // MARK: - Save / discard

    func discard() {
        guard !isSaving else { return }
        onDiscard()
    }

    /// Route the save (see type docs). Returns the encode task (nil when nothing is
    /// encoded) so tests can await it.
    @discardableResult
    func save() -> Task<Void, Never>? {
        guard !isSaving, let cgImage else { return nil }
        let markup = annotations
        let annotated = !markup.isEmpty
        let rect = cropGeometry.cropRect

        if !annotated && cropGeometry.isFullFrame {
            onDiscard()
            return nil
        }

        isSaving = true
        errorMessage = nil
        let metrics = metrics
        return Task { [weak self] in
            let pngData = await Task.detached {
                annotated
                    ? MarkupRenderer.renderPNG(image: cgImage, annotations: markup, crop: rect, metrics: metrics)
                    : ImageCrop.cropAndEncodePNG(cgImage, to: rect)
            }.value
            guard let self else { return }
            guard let pngData else {
                Log.error("ImageEditSession: \(annotated ? "markup render" : "crop")/PNG encode failed")
                self.isSaving = false
                self.errorMessage = "Save failed — try again"
                return
            }
            if annotated {
                self.onSaveAsNew(pngData)
            } else {
                self.onSave(pngData)
            }
        }
    }
}
