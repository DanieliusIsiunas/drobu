import AppKit
import AVKit
import Carbon.HIToolbox
import SwiftUI
@preconcurrency import VisionKit

/// A floating panel that shows clipboard content at near-full size.
/// Attached as a child window to the main FloatingPanel via `addChildWindow`.
/// Can become key (required for VisionKit Live Text selection in images).
/// Dismisses via Shift tap, Escape, or clicking outside both windows.
final class LargePreviewPanel: NSPanel {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        title = "Preview"
    }

    /// Called when a navigation key is pressed while this panel is key.
    /// PanelView sets this to handle arrow/escape/return without key transfer.
    var onNavigationKey: ((_ keyCode: UInt16) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Defer: isKeyWindow on parent may not be updated yet when resignKey fires synchronously
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            // If key went to our parent FloatingPanel, that's fine — stay open
            if let parentPanel = self.parent, parentPanel.isKeyWindow {
                return
            }
            // Key went elsewhere (desktop, other app) — close parent, which cascades to us
            self.parent?.close()
        }
    }

    /// True while this panel hosts an image edit: keys then belong to the editor and
    /// its label field (Esc discards, Return confirms a label, ⌘↩ saves) instead of
    /// list navigation.
    private(set) var isHostingEditor = false

    // Intercept navigation keys BEFORE the responder chain so ImageAnalysisOverlayView
    // can't consume them. Arrow keys always navigate items; text selection is mouse-only.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isHostingEditor {
            reclaimEditorFocusIfNeeded(for: event)
        }
        if event.type == .keyDown, !isHostingEditor {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_Escape, kVK_UpArrow, kVK_DownArrow,
                 kVK_LeftArrow, kVK_RightArrow, kVK_ForwardDelete:
                onNavigationKey?(event.keyCode)
                return  // Don't dispatch to responder chain
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    /// A click on the image with Select text gives Live Text the focus; the editor's
    /// own keys (Esc, ⌘↩, 1–4, Delete, ⌘Z) must still reach it. Everything else —
    /// notably ⌘C for selected text — stays with whoever has focus, and a label
    /// being typed (field editor) is never interrupted.
    private func reclaimEditorFocusIfNeeded(for event: NSEvent) {
        guard !(firstResponder is NSText),
              let keyView = contentView.flatMap(Self.editorKeyView(in:)),
              firstResponder !== keyView else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let ownsKey: Bool
        switch Int(event.keyCode) {
        case kVK_Escape: ownsKey = true
        case kVK_Return: ownsKey = flags == .command
        case kVK_Delete, kVK_ForwardDelete: ownsKey = flags.isEmpty
        default:
            ownsKey = (flags.isEmpty && ["1", "2", "3", "4"].contains(chars))
                || (flags == .command && chars == "z")
        }
        if ownsKey { makeFirstResponder(keyView) }
    }

    private static func editorKeyView(in view: NSView) -> ImageEditorKeyNSView? {
        if let keyView = view as? ImageEditorKeyNSView { return keyView }
        for subview in view.subviews {
            if let found = editorKeyView(in: subview) { return found }
        }
        return nil
    }

    private var hostingView: NSHostingView<LargePreviewContent>?

    // MARK: - Show / Update

    func show(
        for item: ClipboardRecord,
        session: ImageEditSession?,
        onBeginMarkup: ((MarkupTool) -> Void)?,
        on screen: NSScreen
    ) {
        isHostingEditor = session != nil
        let hosting = NSHostingView(rootView: LargePreviewContent(item: item, session: session, onBeginMarkup: onBeginMarkup))
        hosting.rootView = hosting.rootView  // force initial layout
        contentView = hosting
        hostingView = hosting

        // Size: 85% of screen visible frame
        let visibleFrame = screen.visibleFrame
        let width = visibleFrame.width * 0.85
        let height = visibleFrame.height * 0.85
        setContentSize(NSSize(width: width, height: height))
        // Center using actual frame size (may differ from content size due to title bar)
        let frameSize = frame.size
        setFrameOrigin(NSPoint(x: visibleFrame.midX - frameSize.width / 2, y: visibleFrame.midY - frameSize.height / 2))

        if isHostingEditor { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
    }

    /// Refresh the content. Taking over an edit makes this panel key so the editor's
    /// keys and label field receive input.
    func update(for item: ClipboardRecord, session: ImageEditSession?, onBeginMarkup: ((MarkupTool) -> Void)?) {
        let wasHostingEditor = isHostingEditor
        isHostingEditor = session != nil
        hostingView?.rootView = LargePreviewContent(item: item, session: session, onBeginMarkup: onBeginMarkup)
        if isHostingEditor, !wasHostingEditor { makeKey() }
    }
}

// MARK: - Live Text Image View

/// NSImageView that suppresses intrinsic content size so the parent frame controls sizing.
/// Without this, NSImageView reports the image's pixel dimensions as intrinsic size,
/// causing NSHostingView to resize and distort the window frame for large images.
private final class FlexibleImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// Displays an image with VisionKit Live Text overlay for text selection and data detectors.
/// Takes raw `Data` (not `NSImage`) to avoid double decoding in the SwiftUI view body.
struct LiveTextImageView: NSViewRepresentable {
    let imageData: Data
    let contentHash: String
    /// Off while a markup drawing tool is active, so drags draw instead of selecting.
    var isInteractive: Bool = true

    private static let interactionTypes: ImageAnalysisOverlayView.InteractionTypes = [.textSelection, .dataDetectors]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = FlexibleImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Image with selectable text")
        imageView.setAccessibilityRole(.image)

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = isInteractive ? Self.interactionTypes : []
        overlay.trackingImageView = imageView
        overlay.autoresizingMask = [.width, .height]
        imageView.addSubview(overlay)
        context.coordinator.overlay = overlay

        context.coordinator.imageView = imageView
        context.coordinator.setImage(from: imageData, hash: contentHash)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        let types: ImageAnalysisOverlayView.InteractionTypes = isInteractive ? Self.interactionTypes : []
        if context.coordinator.overlay?.preferredInteractionTypes != types {
            context.coordinator.overlay?.preferredInteractionTypes = types
        }
        guard context.coordinator.currentHash != contentHash else { return }
        context.coordinator.setImage(from: imageData, hash: contentHash)
    }

    @MainActor
    final class Coordinator {
        var imageView: NSImageView?
        var overlay: ImageAnalysisOverlayView?
        var currentHash: String?
        nonisolated(unsafe) private var analysisTask: Task<Void, Never>?
        private static let analyzer = ImageAnalyzer()

        private static let cache: NSCache<NSString, ImageAnalysis> = {
            let c = NSCache<NSString, ImageAnalysis>()
            c.countLimit = 30  // Bound memory — menu bar app should stay lightweight
            return c
        }()

        deinit {
            analysisTask?.cancel()
        }

        func setImage(from data: Data, hash: String) {
            currentHash = hash
            analysisTask?.cancel()
            overlay?.analysis = nil  // Clear stale overlay immediately — prevents ghost icon on navigate

            guard let nsImage = NSImage(data: data) else { return }
            imageView?.image = nsImage

            if let cached = Self.cache.object(forKey: hash as NSString) {
                overlay?.analysis = cached
                return
            }

            analysisTask = Task { @MainActor in
                guard !Task.isCancelled, currentHash == hash else { return }
                let config = ImageAnalyzer.Configuration([.text])
                do {
                    let analysis = try await Self.analyzer.analyze(nsImage, orientation: .up, configuration: config)
                    guard !Task.isCancelled, currentHash == hash else { return }
                    Self.cache.setObject(analysis, forKey: hash as NSString)
                    overlay?.analysis = analysis
                } catch {
                    Log.error("LiveTextImageView: analysis failed: \(error)")
                }
            }
        }
    }
}

// MARK: - SwiftUI Content

struct LargePreviewContent: View {
    let item: ClipboardRecord
    /// The active image edit, when this preview hosts the editor.
    var session: ImageEditSession?
    /// Picking a drawing tool on a still image starts an edit of it (nil: no markup bar).
    var onBeginMarkup: ((MarkupTool) -> Void)?

    @State private var markupColor = MarkupDefaults.loadColor()

    var body: some View {
        ZStack {
            VisualEffectBackground()
            previewContent
                .padding(16)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.kind {
        case ClipboardRecord.kindImage:
            if let session {
                ImageCropView(session: session, presentation: .large)
            } else {
                VStack(spacing: 0) {
                    imagePreview
                    markupBar
                }
            }
        case ClipboardRecord.kindGif:
            gifPreview
        case ClipboardRecord.kindVideo:
            videoPreview
        default:
            textPreview
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let data = item.imageData {
            if ImageAnalyzer.isSupported {
                LiveTextImageView(imageData: data, contentHash: item.contentHash)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image preview with selectable text")
            } else if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image preview")
            } else {
                unavailable("photo", "Unable to load image")
            }
        } else {
            unavailable("photo", "Unable to load image")
        }
    }

    /// View-mode bar: Select text (Live Text, as always) is active; picking a drawing
    /// tool starts an edit of this image right here.
    @ViewBuilder
    private var markupBar: some View {
        if let onBeginMarkup, let data = item.imageData, ImageCrop.isBitmapData(data) {
            HStack {
                MarkupToolbar(
                    tools: MarkupTool.allCases,
                    selectedTool: .select,
                    color: markupColor,
                    onTool: { tool in if tool.draws { onBeginMarkup(tool) } },
                    onColor: { swatch in
                        markupColor = swatch
                        MarkupDefaults.saveColor(swatch)
                    }
                )
                Spacer()
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var gifPreview: some View {
        if let data = item.imageData {
            AnimatedGIFView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Animated GIF preview")
        } else {
            unavailable("play.rectangle", "Unable to load GIF")
        }
    }

    @ViewBuilder
    private var videoPreview: some View {
        let url = ClipboardRecord.videoPath(for: item.contentHash)
        if FileManager.default.fileExists(atPath: url.path) {
            InlineVideoPlayerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Video preview")
        } else if let data = item.imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Video thumbnail")
        } else {
            unavailable("video.fill", "Video file not found")
        }
    }

    private var textPreview: some View {
        ReadOnlyTextView(text: item.plainText ?? "")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ icon: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Read-Only Text View (NSTextView wrapper for large content)

private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        textView.setAccessibilityLabel("Full text content")

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}
