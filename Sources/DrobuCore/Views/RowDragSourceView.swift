import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Classifies a row press as the Shift+Click selection gesture (KTD6).
///
/// Takes **raw** `NSEvent.modifierFlags` and masks internally to
/// `shiftTapRelevantModifiers` (the four chordable modifiers, defined next to
/// `shiftTapDecision` in `ShiftTapDetector.swift`) so no caller can forget the
/// mask. Masking is load-bearing, not hygiene: real device flags carry Caps Lock,
/// Fn and `.numericPad` bits — the same noise documented in
/// `.claude/rules/swiftui-keypress-gotchas.md` that makes `modifiers.isEmpty`
/// always false for arrow keys — so an unmasked `== [.shift]` comparison would
/// silently stop toggling rows the moment Caps Lock is on.
/// (`shiftTapDecision` takes *pre-masked* flags instead because it compares two
/// states across events and `FloatingPanel` stores the masked baseline; here
/// there is one event and no stored state, so masking belongs inside.)
///
/// The press is a Shift gesture **iff** the masked flags are exactly `[.shift]`.
/// Equality rather than `.contains(.shift)`: Shift+Command, Shift+Option and
/// Shift+Control must all stay "plain" so a chord — a user's own, or one passing
/// through from the system — can never be mistaken for a selection toggle.
func isShiftClickGesture(_ rawFlags: NSEvent.ModifierFlags) -> Bool {
    rawFlags.intersection(shiftTapRelevantModifiers) == [.shift]
}

/// Transparent AppKit overlay that gives a clipboard row a native mouse lifecycle:
/// a press reports its modifier state (`onPress`), a within-threshold release
/// re-emits the row's tap (paste), a press dragged past the threshold begins an
/// `NSDraggingSession` carrying real files (drag-out).
///
/// AppKit rather than SwiftUI `.onDrag` because the macOS-14 floor has no
/// end-of-drag callback (`onDragSessionUpdated` is 26+), no multi-type pasteboard
/// composition, and no click-vs-drag threshold control (KTD2). Modeled on
/// `CropOverlayView`'s NSView shape: `acceptsFirstMouse`, and
/// `mouseDownCanMoveWindow = false` — load-bearing against the panel's
/// `isMovableByWindowBackground`, or a row drag would move the whole panel.
struct RowDragSourceView: NSViewRepresentable {
    /// The press itself, fired at mouseDown with `isShift` = "the selection
    /// gesture" (exactly Shift held — see `isShiftClickGesture`). The owner
    /// mutates the selection here: a Shift press toggles this row, a plain press
    /// outside the current selection collapses onto it (KTD6).
    ///
    /// Defaulted so a call site that only wants tap + drag stays valid.
    var onPress: (_ isShift: Bool) -> Void = { _ in }
    /// The row's click action (select + paste) — fired on a within-threshold
    /// release, and only for a **non-Shift** press (a Shift press did its work at
    /// mouseDown; releasing must not also paste).
    var onTap: () -> Void
    /// Participant records for a drag started on this row, evaluated at mouseDown
    /// (KTD3 — snapshot before `items` can refire mid-gesture). Empty → no drag.
    var dragRecords: () -> [ClipboardRecord]

    func makeNSView(context: Context) -> RowDragSourceNSView {
        let view = RowDragSourceNSView()
        view.onPress = onPress
        view.onTap = onTap
        view.dragRecords = dragRecords
        view.setAccessibilityElement(false)  // SwiftUI row keeps the VoiceOver contract
        return view
    }

    func updateNSView(_ nsView: RowDragSourceNSView, context: Context) {
        nsView.onPress = onPress
        nsView.onTap = onTap
        nsView.dragRecords = dragRecords
    }
}

final class RowDragSourceNSView: NSView, NSDraggingSource {
    var onPress: (_ isShift: Bool) -> Void = { _ in }
    var onTap: () -> Void = {}
    var dragRecords: () -> [ClipboardRecord] = { [] }

    private var mouseDownEvent: NSEvent?
    private var snapshot: [ClipboardRecord] = []
    private var dragStarted = false
    /// Whether the in-flight press is the Shift+Click selection gesture, decided
    /// once from the mouseDown event's flags. `mouseUp` reads THIS, never
    /// `NSEvent.modifierFlags`: the user can release Shift before lifting the
    /// mouse, and a re-read would then paste a row it had just toggled.
    private var pressWasShiftGesture = false
    /// The panel captured at drag start, so the end-of-session callback still
    /// clears the drag flag if this view's `window` detaches mid-drag (the row
    /// leaving the LazyVStack). Reading `window` in `endedAt` could return nil.
    private weak var owningPanel: FloatingPanel?
    /// Click-vs-drag hysteresis. AppKit exposes no public constant; ~4pt sits
    /// between WebKit's text (3) and image (5) drag thresholds and tolerates
    /// normal click jitter. Erring larger is safe; smaller silently breaks paste.
    private let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
        // Classify from THIS event's flags, once (KTD6). Toggling at mouseDown
        // matches NSTableView, and it means a Shift+Click that jitters past the
        // drag threshold still registers its toggle instead of silently no-op'ing.
        pressWasShiftGesture = isShiftClickGesture(event.modifierFlags)
        // ORDER IS LOAD-BEARING: the press mutates the selection (Shift toggles
        // this row; a plain press outside the selection collapses onto it), and
        // the snapshot below must reflect the POST-mutation selection so a press
        // that becomes a drag carries the rows the user just selected. Snapshot
        // first and a Shift+drag would ship the pre-toggle set. KTD6.
        onPress(pressWasShiftGesture)
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
        defer { mouseDownEvent = nil; snapshot = []; pressWasShiftGesture = false }
        // A within-threshold release is a click → the row's paste action. A release
        // after the threshold (drag started, or a gate-failed no-op) does nothing.
        guard !dragStarted else { return }
        // A Shift gesture already did its work at mouseDown (the toggle), so its
        // release must not also paste — otherwise every cherry-pick would close
        // the panel. Reads the mouseDown classification, not the current flags.
        guard !pressWasShiftGesture else { return }
        onTap()
    }

    private func beginDrag() {
        guard let event = mouseDownEvent else { return }
        let payloads: [DragExport.Payload]
        do {
            payloads = try DragExport.payloads(for: snapshot, stagingRoot: DragExport.stagingDirectory)
        } catch {
            // Never interpolate the error: a Data.write failure's description embeds
            // the destination path, and a multi-drag text file's name is derived from
            // clipboard content — log the code only, never content (repo rule).
            Log.error("RowDragSourceView: staging failed — drag aborted (\((error as NSError).domain) \((error as NSError).code))")
            return  // no session, no tap (threshold already crossed)
        }
        guard !payloads.isEmpty else { return }  // gate failed (R6): missing content

        let items = payloads.enumerated().map { makeDraggingItem($0.element, index: $0.offset) }

        owningPanel = window as? FloatingPanel
        owningPanel?.beginDragSession()
        beginDraggingSession(with: items, event: event, source: self)
    }

    private func makeDraggingItem(_ payload: DragExport.Payload, index: Int) -> NSDraggingItem {
        let item: NSDraggingItem
        let dragImage: NSImage

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
        case let .string(text):
            item = NSDraggingItem(pasteboardWriter: text as NSString)
            dragImage = NSWorkspace.shared.icon(for: .plainText)
        }

        let size = NSSize(width: 48, height: 48)
        dragImage.size = size
        // Fan multi-drags out slightly so the stack reads as several files (v1 uses
        // the file-type icon as the preview; a thumbnail/label component is follow-up).
        let frame = NSRect(x: CGFloat(index) * 6, y: CGFloat(index) * -6, width: size.width, height: size.height)
        item.setDraggingFrame(frame, contents: dragImage)
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
        // Use the captured panel (window may be nil if the row detached mid-drag).
        owningPanel?.dragSessionEnded(accepted: operation != [])
        owningPanel = nil
        // The terminal mouse-up is consumed by the drag machinery, so mouseUp's
        // defer won't fire — release the (possibly large) record snapshot here.
        snapshot = []
        mouseDownEvent = nil
        dragStarted = false
        pressWasShiftGesture = false
    }
}
