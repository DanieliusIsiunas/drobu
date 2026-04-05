import AppKit
import AVKit
import Carbon.HIToolbox
import SwiftUI
import VisionKit

/// A floating panel that shows clipboard content at near-full size.
/// Attached as a child window to the main FloatingPanel via `addChildWindow`.
/// Can become key (required for VisionKit Live Text selection in images).
/// Dismisses via Shift tap, Escape, or clicking outside both windows.
final class LargePreviewPanel: NSPanel {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
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

    // Intercept navigation keys BEFORE the responder chain so ImageAnalysisOverlayView
    // can't consume them. Arrow keys always navigate items; text selection is mouse-only.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
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

    private var hostingView: NSHostingView<LargePreviewContent>?

    // MARK: - Show / Update

    func show(for item: ClipboardRecord, on screen: NSScreen) {
        let hosting = NSHostingView(rootView: LargePreviewContent(item: item))
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

        orderFront(nil)
    }

    func update(for item: ClipboardRecord) {
        hostingView?.rootView = LargePreviewContent(item: item)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = FlexibleImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        overlay.trackingImageView = imageView
        overlay.autoresizingMask = [.width, .height]
        imageView.addSubview(overlay)
        context.coordinator.overlay = overlay

        context.coordinator.imageView = imageView
        context.coordinator.setImage(from: imageData, hash: contentHash)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
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

    var body: some View {
        ZStack {
            VisualEffectBackground()
            previewContent
                .padding(16)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.kind {
        case ClipboardRecord.kindImage:
            imagePreview
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
            } else if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailable("photo", "Unable to load image")
            }
        } else {
            unavailable("photo", "Unable to load image")
        }
    }

    @ViewBuilder
    private var gifPreview: some View {
        if let data = item.imageData {
            AnimatedGIFView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        } else if let data = item.imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }
}
