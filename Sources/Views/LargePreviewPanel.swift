import AppKit
import AVKit
import SwiftUI

/// A display-only floating panel that shows clipboard content at near-full size.
/// Attached as a child window to the main FloatingPanel via `addChildWindow`.
/// Cannot become key — purely visual, dismisses via Shift tap or Escape.
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
        setFrameOrigin(NSPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2))

        orderFront(nil)
    }

    func update(for item: ClipboardRecord) {
        hostingView?.rootView = LargePreviewContent(item: item)
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
        if let data = item.imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
