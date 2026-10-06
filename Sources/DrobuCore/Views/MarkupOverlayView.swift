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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkupOverlayNSView {
        let view = MarkupOverlayNSView()
        let coordinator = context.coordinator
        view.onAnnotationsChange = { coordinator.parent.annotations = $0 }
        view.onSelectionChange = { coordinator.parent.selectedID = $0 }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Markup canvas")
        // The didSet below only fires on a change, so seed the empty-canvas value.
        view.setAccessibilityValue(MarkupOverlayNSView.accessibilityValue(count: annotations.count))
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

final class MarkupOverlayNSView: NSView, NSTextViewDelegate {
    var annotations: [MarkupAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(Self.accessibilityValue(count: annotations.count))
        }
    }
    static func accessibilityValue(count: Int) -> String {
        count == 1 ? "1 annotation" : "\(count) annotations"
    }

    var selectedID: UUID? {
        didSet { if selectedID != oldValue { needsDisplay = true } }
    }
    var tool: MarkupTool = .box {
        didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
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
    private static let commentPlaceholder = "Comment (optional)"
    private static let notePlaceholder = "Note"

    /// Screen-space gesture thresholds, converted to content pixels per gesture.
    private let clickThresholdPoints: CGFloat = 4
    private let hitTolerancePoints: CGFloat = 6

    private var pressStartView: CGPoint?
    private var isDragging = false
    private var draft: MarkupAnnotation?

    private var editingID: UUID?
    private var field: LabelTextView?
    /// A note being dragged: its id and the annotation as it was at mouseDown.
    private var movingNote: MarkupAnnotation?

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
    /// With the Select text tool, presses fall through to Live Text below — except
    /// onto an open label field, which must stay clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled else { return nil }
        if !tool.draws {
            guard let field else { return nil }
            return field.hitTest(convert(point, from: superview))
        }
        let local = convert(point, from: superview)
        guard fitted.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        // Clicking anywhere else on the canvas commits an open label first.
        if editingID != nil { finishEditing() }
        let start = convert(event.locationInWindow, from: nil)
        pressStartView = start
        isDragging = false
        draft = nil
        // A press on a note's pill drags the note instead of drawing.
        movingNote = nil
        let pills = MarkupRenderer.pillRects(for: annotations, metrics: metrics, bounds: geometry.cropRect)
        if let hit = ImageMarkup.hitTest(contentPoint(start), annotations: annotations, pillRects: pills,
                                         tolerance: hitTolerancePoints * contentPerPoint),
           let note = annotations.first(where: { $0.id == hit }), note.shape.isNote {
            movingNote = note
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStartView else { return }
        let location = convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard !ImageMarkup.isClick(from: start, to: location, threshold: clickThresholdPoints) else { return }
            isDragging = true
            setSelection(movingNote?.id)
        }
        let a = contentPoint(start)
        let b = contentPoint(location)
        if let original = movingNote, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            let delta = CGSize(width: b.x - a.x, height: b.y - a.y)
            annotations[index] = ImageMarkup.moved(original, by: delta, within: geometry.cropRect)
            return
        }
        switch tool {
        case .box:
            draft = MarkupAnnotation(
                id: draft?.id ?? UUID(),
                shape: .box(ImageMarkup.rect(from: a, to: b, clampedTo: geometry.contentBounds)),
                color: color
            )
        case .arrow:
            draft = MarkupAnnotation(id: draft?.id ?? UUID(), shape: .arrow(tail: a, head: b), color: color)
        case .note, .select:
            draft = nil // notes are placed by a click, not a drag; select never draws
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressStartView else { return }
        pressStartView = nil
        defer { needsDisplay = true }

        if isDragging, movingNote != nil {
            isDragging = false
            movingNote = nil
            update(annotations)  // publish the moved note
            return
        }
        movingNote = nil

        if isDragging {
            isDragging = false
            guard let committed = draft else { return }
            draft = nil
            // A drag that wandered past the threshold but ended back near its start
            // draws nothing meaningful — drop it, or the invisible shape would turn
            // a plain ⌘↩ crop save into a save-as-new-item.
            let end = convert(event.locationInWindow, from: nil)
            if ImageMarkup.isClick(from: start, to: end, threshold: clickThresholdPoints) { return }
            // ...or that moved on screen but clamped to a single image edge.
            if ImageMarkup.isDegenerate(committed.shape, minimumLength: clickThresholdPoints * contentPerPoint) { return }
            update(annotations + [committed])
            if case .box = committed.shape { beginEditing(committed.id) }
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
                beginEditing(hit)
            }
        } else if tool == .note {
            setSelection(nil)
            let note = MarkupAnnotation(shape: .note(point), color: color)
            update(annotations + [note])
            beginEditing(note.id)
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

    /// The editor is moving to the other surface (or closing): commit a label being
    /// typed so it isn't lost with this view.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, editingID != nil { finishEditing() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Inline label editor

    private func beginEditing(_ id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        editingID = id

        let k = contentPerPoint
        let textColor: NSColor = annotation.color.usesDarkLabelText ? .black : .white
        let textView = LabelTextView(frame: .zero)
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: max(11, metrics.fontSize / k), weight: .bold)
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(cgColor: annotation.color.cgColor()) ?? .systemRed
        textView.textContainerInset = NSSize(width: metrics.pillPaddingX / k, height: metrics.pillPaddingY / k)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.focusRingType = .none
        textView.wantsLayer = true
        textView.layer?.cornerRadius = metrics.pillCornerRadius / k
        textView.layer?.masksToBounds = true
        textView.placeholder = annotation.shape.isNote ? Self.notePlaceholder : Self.commentPlaceholder
        textView.string = annotation.text
        textView.setAccessibilityLabel(annotation.shape.isNote ? "Note text" : "Highlight comment")
        textView.setAccessibilityHelp("Return adds a line. Escape or Command-Return finishes.")
        addSubview(textView)
        field = textView
        repositionField()
        needsDisplay = true
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Size and place the editor exactly where — and as large as — the finished pill
    /// will render for the text typed so far (the placeholder while empty), so the
    /// label doesn't jump when editing ends.
    private func repositionField() {
        guard let field, let id = editingID,
              var annotation = annotations.first(where: { $0.id == id }) else { return }
        annotation.text = field.string.isEmpty ? field.placeholder : field.string
        // A shape outside the crop has no pill there; still show the editor at its
        // image position so typing stays visible.
        guard let pill = MarkupRenderer.pillRect(for: annotation, metrics: metrics, bounds: geometry.cropRect)
            ?? MarkupRenderer.pillRect(for: annotation, metrics: metrics, bounds: geometry.contentBounds) else { return }
        // A little slack so AppKit's line breaking never wraps earlier than CoreText's.
        field.frame = viewRect(fromContent: pill).insetBy(dx: -2, dy: -1).integral
    }

    /// Finish editing and keep the text — Esc, ⌘↩, a click elsewhere, a tool or
    /// colour change, and the editor moving surfaces all end here, as in Preview,
    /// Figma and Excalidraw. An empty note is removed; an empty box comment just
    /// leaves the box unlabelled.
    private func finishEditing() {
        guard let id = editingID, let field else { return }
        // Clear state first: removing the editor ends editing, which re-enters
        // textDidEndEditing.
        editingID = nil
        self.field = nil
        let text = ImageMarkup.normalizedLabel(field.string)
        field.delegate = nil
        field.removeFromSuperview()

        if let index = annotations.firstIndex(where: { $0.id == id }) {
            var next = annotations
            next[index].text = text
            if next[index].shape.isNote && text.isEmpty {
                next.remove(at: index)
            }
            update(next)
        }
        needsDisplay = true
        focus?.restore()
    }

    func textDidChange(_ notification: Notification) {
        repositionField()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return / Shift-Return insert a line break (the text view's default).
        // Esc finishes and keeps the text instead of showing word completion.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        // Focus left the editor some other way (e.g. a click on the info bar).
        if editingID != nil { finishEditing() }
    }

    /// ⌘↩ while typing finishes the note; a second ⌘↩ (now at the editor's key
    /// view) saves the image. It arrives as a key equivalent before the text view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editingID != nil, EditorKeyNSView.isSaveKey(event) {
            finishEditing()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        // Select text hands the image to Live Text, which shows its own cursors.
        guard isInteractionEnabled, tool.draws else { return }
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

/// The in-place label editor, styled like the finished pill (colour, bold font,
/// padding, rounded corners) so nothing jumps when editing ends. Return adds a
/// line; the placeholder is drawn while the text is empty.
final class LabelTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (textColor ?? .white).withAlphaComponent(0.55),
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
