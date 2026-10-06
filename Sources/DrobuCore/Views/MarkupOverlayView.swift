import AppKit
import SwiftUI

/// Weak handle to the image editor's first-responder key view, so the markup
/// overlay can hand focus back after a label edit. Without the handback, focus falls
/// to the window and Esc / ⌘↩ / 1–4 / Delete / ⌘Z all stop working.
@MainActor
final class EditorFocusHandle {
    weak var keyView: NSView?

    func restore() {
        guard let keyView, let window = keyView.window else { return }
        window.makeFirstResponder(keyView)
    }
}

/// Hand-drawn markup layer for the image editor (box + label, arrow, note).
///
/// Sits in the editor's ZStack BELOW `CropOverlayView`: the crop overlay claims only
/// its corner grips, so corner drags still crop and every other press on the image
/// lands here. Drawing goes through `MarkupRenderer` — the same code that renders
/// the saved PNG — so what you see is what gets saved.
///
/// Select-vs-draw is decided on mouseUp: a press that moves past the click threshold
/// always draws with the current tool, wherever it started; a click selects the
/// annotation under it (or places a note, or clears the selection).
struct MarkupOverlayView: NSViewRepresentable {
    @Binding var annotations: [MarkupAnnotation]
    @Binding var selectedID: UUID?
    let tool: MarkupTool
    let color: MarkupColor
    let metrics: MarkupMetrics
    let geometry: CropGeometry
    var isInteractionEnabled: Bool = true
    let focus: EditorFocusHandle
    /// Commit any open label, then save — ⌘↩ while typing a label.
    var onRequestSave: (([MarkupAnnotation]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkupOverlayNSView {
        let view = MarkupOverlayNSView()
        let coordinator = context.coordinator
        view.onAnnotationsChange = { coordinator.parent.annotations = $0 }
        view.onSelectionChange = { coordinator.parent.selectedID = $0 }
        view.onRequestSave = { coordinator.parent.onRequestSave?($0) }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Markup canvas")
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: MarkupOverlayNSView, context: Context) {
        context.coordinator.parent = self
        apply(to: nsView)
    }

    private func apply(to view: MarkupOverlayNSView) {
        view.focus = focus
        view.tool = tool
        view.color = color
        view.metrics = metrics
        view.geometry = geometry
        view.isInteractionEnabled = isInteractionEnabled
        view.selectedID = selectedID
        view.annotations = annotations
    }

    @MainActor
    final class Coordinator {
        var parent: MarkupOverlayView
        init(_ parent: MarkupOverlayView) { self.parent = parent }
    }
}

// MARK: - Native view

final class MarkupOverlayNSView: NSView, NSTextFieldDelegate {
    var annotations: [MarkupAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(annotations.count == 1 ? "1 annotation" : "\(annotations.count) annotations")
        }
    }
    var selectedID: UUID? {
        didSet { if selectedID != oldValue { needsDisplay = true } }
    }
    var tool: MarkupTool = .box
    var color: MarkupColor = .red
    var metrics = MarkupMetrics(densityScale: 1) {
        didSet { if metrics != oldValue { needsDisplay = true } }
    }
    var geometry = CropGeometry(contentWidth: 0, contentHeight: 0) {
        didSet {
            guard geometry != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            repositionField()
        }
    }
    var isInteractionEnabled = true
    weak var focus: EditorFocusHandle?

    var onAnnotationsChange: (([MarkupAnnotation]) -> Void)?
    var onSelectionChange: ((UUID?) -> Void)?
    var onRequestSave: (([MarkupAnnotation]) -> Void)?

    private static let commentPlaceholder = "Comment (optional)"
    private static let notePlaceholder = "Note"

    /// Screen-space gesture thresholds, converted to content pixels per gesture.
    private let clickThresholdPoints: CGFloat = 4
    private let hitTolerancePoints: CGFloat = 6

    private var pressStartView: CGPoint?
    private var isDragging = false
    private var draft: MarkupAnnotation?

    private var editingID: UUID?
    private var editingIsNew = false
    private var field: NSTextField?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Geometry helpers

    private var fitted: CGRect { geometry.fittedRect(in: bounds.size) }

    /// Content pixels per view point at the current zoom.
    private var contentPerPoint: CGFloat {
        let f = fitted
        guard f.width > 0 else { return 1 }
        return CGFloat(geometry.contentWidth) / f.width
    }

    private func contentPoint(_ viewPoint: CGPoint) -> CGPoint {
        geometry.contentPoint(fromViewPoint: viewPoint, fittedRect: fitted)
    }

    private func viewRect(fromContent rect: CGRect) -> CGRect {
        let f = fitted
        let k = 1 / contentPerPoint
        return CGRect(x: f.minX + rect.minX * k, y: f.minY + rect.minY * k, width: rect.width * k, height: rect.height * k)
    }

    // MARK: Hit testing

    /// Claim presses on the image; the letterbox margin still drags the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled else { return nil }
        let local = convert(point, from: superview)
        guard fitted.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        // Clicking anywhere else on the canvas commits an open label first.
        if editingID != nil { endEditing(commit: true) }
        pressStartView = convert(event.locationInWindow, from: nil)
        isDragging = false
        draft = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStartView else { return }
        let location = convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard !ImageMarkup.isClick(from: start, to: location, threshold: clickThresholdPoints) else { return }
            isDragging = true
            setSelection(nil)
        }
        let a = contentPoint(start)
        let b = contentPoint(location)
        switch tool {
        case .box:
            draft = MarkupAnnotation(
                id: draft?.id ?? UUID(),
                shape: .box(ImageMarkup.rect(from: a, to: b, clampedTo: geometry.contentBounds)),
                color: color
            )
        case .arrow:
            draft = MarkupAnnotation(id: draft?.id ?? UUID(), shape: .arrow(tail: a, head: b), color: color)
        case .note:
            draft = nil // notes are placed by a click, not a drag
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressStartView else { return }
        pressStartView = nil
        defer { needsDisplay = true }

        if isDragging {
            isDragging = false
            guard let committed = draft else { return }
            draft = nil
            update(annotations + [committed])
            if case .box = committed.shape { beginEditing(committed.id, isNew: true) }
            return
        }

        // A click: select what's under it, place a note, or clear the selection.
        let point = contentPoint(start)
        let pills = MarkupRenderer.pillRects(for: annotations, metrics: metrics, bounds: geometry.cropRect)
        if let hit = ImageMarkup.hitTest(point, annotations: annotations, pillRects: pills,
                                         tolerance: hitTolerancePoints * contentPerPoint) {
            setSelection(hit)
            if event.clickCount >= 2, let annotation = annotations.first(where: { $0.id == hit }),
               annotation.shape.acceptsText {
                beginEditing(hit, isNew: false)
            }
        } else if tool == .note {
            setSelection(nil)
            let note = MarkupAnnotation(shape: .note(point), color: color)
            update(annotations + [note])
            beginEditing(note.id, isNew: true)
        } else {
            setSelection(nil)
        }
    }

    private func update(_ newValue: [MarkupAnnotation]) {
        annotations = newValue
        onAnnotationsChange?(newValue)
    }

    private func setSelection(_ id: UUID?) {
        selectedID = id
        onSelectionChange?(id)
    }

    // MARK: Inline label field

    private func beginEditing(_ id: UUID, isNew: Bool) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        editingID = id
        editingIsNew = isNew

        let textField = NSTextField(string: annotation.text)
        textField.delegate = self
        textField.isBezeled = false
        textField.isBordered = false
        textField.focusRingType = .none
        textField.drawsBackground = true
        textField.backgroundColor = NSColor(cgColor: annotation.color.cgColor()) ?? .systemRed
        textField.textColor = annotation.color.usesDarkLabelText ? .black : .white
        textField.font = .systemFont(ofSize: max(11, metrics.fontSize / contentPerPoint), weight: .bold)
        textField.placeholderString = annotation.shape.isNote ? Self.notePlaceholder : Self.commentPlaceholder
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.setAccessibilityLabel(annotation.shape.isNote ? "Note text" : "Highlight comment")
        addSubview(textField)
        field = textField
        repositionField()
        needsDisplay = true
        window?.makeFirstResponder(textField)
    }

    /// Place the field where the annotation's pill will render.
    private func repositionField() {
        guard let field, let id = editingID,
              var annotation = annotations.first(where: { $0.id == id }) else { return }
        // Size an empty field for its placeholder.
        if annotation.text.isEmpty { annotation.text = Self.commentPlaceholder }
        guard let pill = MarkupRenderer.pillRect(for: annotation, metrics: metrics, bounds: geometry.cropRect) else { return }
        var frame = viewRect(fromContent: pill)
        frame.size.width = max(frame.width, 160)
        frame.size.height = max(frame.height, 20)
        field.frame = frame
    }

    private func endEditing(commit: Bool) {
        guard let id = editingID, let field else { return }
        // Clear state first: removing the field ends editing, which re-enters the
        // delegate's controlTextDidEndEditing.
        editingID = nil
        self.field = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()

        if let index = annotations.firstIndex(where: { $0.id == id }) {
            var next = annotations
            if commit { next[index].text = text }
            // An empty note is discarded (committed empty, or a new note cancelled).
            if next[index].shape.isNote && next[index].text.isEmpty {
                next.remove(at: index)
            }
            update(next)
        }
        needsDisplay = true
        focus?.restore()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let saveAfter = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            endEditing(commit: true)
            if saveAfter { onRequestSave?(annotations) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc cancels only the label edit (otherwise the field editor would show
            // word completion); a second Esc reaches the editor and discards all.
            endEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus left the field some other way (e.g. a click on the info bar).
        if editingID != nil { endEditing(commit: true) }
    }

    /// ⌘↩ may arrive as a key equivalent before the field editor sees it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editingID != nil, event.keyCode == 36,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            endEditing(commit: true)
            onRequestSave?(annotations)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        guard isInteractionEnabled else { return }
        addCursorRect(fitted.intersection(bounds), cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard geometry.contentWidth > 0, geometry.contentHeight > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let f = fitted
        guard f.width > 0, f.height > 0 else { return }

        context.saveGState()
        context.clip(to: f)
        context.translateBy(x: f.minX, y: f.minY)
        let k = 1 / contentPerPoint
        context.scaleBy(x: k, y: k)
        var all = annotations
        if let draft { all.append(draft) }
        MarkupRenderer.draw(all, in: context, metrics: metrics, bounds: geometry.cropRect, hidingPillOf: editingID)
        context.restoreGState()

        drawSelectionOutline()
    }

    /// View-only chrome around the selected annotation; never exported.
    private func drawSelectionOutline() {
        guard let id = selectedID, let annotation = annotations.first(where: { $0.id == id }) else { return }
        var content: CGRect
        switch annotation.shape {
        case .box(let rect): content = rect
        case .arrow(let tail, let head):
            content = CGRect(x: min(tail.x, head.x), y: min(tail.y, head.y),
                             width: abs(head.x - tail.x), height: abs(head.y - tail.y))
        case .note: content = .null
        }
        if let pill = MarkupRenderer.pillRect(for: annotation, metrics: metrics, bounds: geometry.cropRect) {
            content = content.isNull ? pill : content.union(pill)
        }
        let rect = viewRect(fromContent: content).insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.setStroke()
        path.stroke()
    }
}
