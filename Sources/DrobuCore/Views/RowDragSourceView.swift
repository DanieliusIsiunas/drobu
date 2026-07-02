import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Transparent AppKit overlay that gives a clipboard row a native mouse lifecycle:
/// a within-threshold press re-emits the row's tap (paste), a press dragged past
/// the threshold begins an `NSDraggingSession` carrying real files (drag-out).
///
/// AppKit rather than SwiftUI `.onDrag` because the macOS-14 floor has no
/// end-of-drag callback (`onDragSessionUpdated` is 26+), no multi-type pasteboard
/// composition, and no click-vs-drag threshold control (KTD2). Modeled on
/// `CropOverlayView`'s NSView shape: `acceptsFirstMouse`, and
/// `mouseDownCanMoveWindow = false` — load-bearing against the panel's
/// `isMovableByWindowBackground`, or a row drag would move the whole panel.
struct RowDragSourceView: NSViewRepresentable {
    /// The row's click action (select + paste) — fired on a within-threshold release.
    var onTap: () -> Void
    /// Participant records for a drag started on this row, evaluated at mouseDown
    /// (KTD3 — snapshot before `items` can refire mid-gesture). Empty → no drag.
    var dragRecords: () -> [ClipboardRecord]

    func makeNSView(context: Context) -> RowDragSourceNSView {
        let view = RowDragSourceNSView()
        view.onTap = onTap
        view.dragRecords = dragRecords
        view.setAccessibilityElement(false)  // SwiftUI row keeps the VoiceOver contract
        return view
    }

    func updateNSView(_ nsView: RowDragSourceNSView, context: Context) {
        nsView.onTap = onTap
        nsView.dragRecords = dragRecords
    }
}

final class RowDragSourceNSView: NSView, NSDraggingSource {
    var onTap: () -> Void = {}
    var dragRecords: () -> [ClipboardRecord] = { [] }

    private var mouseDownEvent: NSEvent?
    private var snapshot: [ClipboardRecord] = []
    private var dragStarted = false
    /// Click-vs-drag hysteresis. AppKit exposes no public constant; ~4pt sits
    /// between WebKit's text (3) and image (5) drag thresholds and tolerates
    /// normal click jitter. Erring larger is safe; smaller silently breaks paste.
    private let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
        // Snapshot the participant records now — items[] can refire between here and
        // the threshold crossing (0.5s clipboard poll, filter reindex). KTD3.
        snapshot = dragRecords()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, !dragStarted else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard abs(dx) > dragThreshold || abs(dy) > dragThreshold else { return }
        dragStarted = true  // threshold crossed → this gesture is a drag, never a tap
        beginDrag()
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil; snapshot = [] }
        // A within-threshold release is a click → the row's paste action. A release
        // after the threshold (drag started, or a gate-failed no-op) does nothing.
        guard !dragStarted else { return }
        onTap()
    }

    private func beginDrag() {
        guard let event = mouseDownEvent else { return }
        let payloads: [DragExport.Payload]
        do {
            payloads = try DragExport.payloads(for: snapshot, stagingRoot: DragExport.stagingDirectory)
        } catch {
            Log.error("RowDragSourceView: staging failed — drag aborted: \(error)")
            return  // no session, no tap (threshold already crossed)
        }
        guard !payloads.isEmpty else { return }  // gate failed (R6): missing content

        let items = payloads.enumerated().map { makeDraggingItem($0.element, index: $0.offset) }

        (window as? FloatingPanel)?.beginDragSession()
        beginDraggingSession(with: items, event: event, source: self)
    }

    private func makeDraggingItem(_ payload: DragExport.Payload, index: Int) -> NSDraggingItem {
        let item: NSDraggingItem
        let dragImage: NSImage
        let label: String

        switch payload {
        case let .file(url, secondaryPNG):
            if let png = secondaryPNG {
                // Image single-drag: file URL + raw bitmap on one pasteboard item so
                // canvas/rich-text targets can take the bitmap. A bare NSURL can't.
                let pbItem = NSPasteboardItem()
                pbItem.setString(url.absoluteString, forType: .fileURL)
                pbItem.setData(png, forType: .png)
                item = NSDraggingItem(pasteboardWriter: pbItem)
            } else {
                // NSURL writer also emits the legacy filenames flavor for old consumers.
                item = NSDraggingItem(pasteboardWriter: url as NSURL)
            }
            dragImage = NSWorkspace.shared.icon(forFile: url.path)
            label = url.lastPathComponent
        case let .string(text):
            item = NSDraggingItem(pasteboardWriter: text as NSString)
            dragImage = NSWorkspace.shared.icon(for: .plainText)
            label = String(text.prefix(20))
        }

        let size = NSSize(width: 48, height: 48)
        dragImage.size = size
        // Fan multi-drags out slightly so the stack reads as several files.
        let frame = NSRect(x: CGFloat(index) * 6, y: CGFloat(index) * -6, width: size.width, height: size.height)
        item.setDraggingFrame(frame, contents: dragImage)
        item.imageComponentsProvider = nil  // default icon rendering
        _ = label  // reserved for a future label component; icon is the v1 preview
        return item
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return .copy  // never .move — file-kind drags carry the user's originals
        case .withinApplication:
            return []  // no self-drop (R8): dropping back on the panel is inert
        @unknown default:
            return .copy
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Non-empty operation = a target accepted the drop → close (mirrors paste).
        // Empty (NSDragOperationNone) = cancelled or rejected → panel stays open.
        (window as? FloatingPanel)?.dragSessionEnded(accepted: operation != [])
    }
}
