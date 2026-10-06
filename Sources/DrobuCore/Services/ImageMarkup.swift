import CoreGraphics
import Foundation

// Pure model and geometry for the image editor's hand-drawn markup (box, arrow,
// note). Lives in Services/ next to `CropGeometry` so it is testable without a view.
//
// Every coordinate is in **content pixels with a top-left origin** — the same space
// `CropGeometry.cropRect` uses — so panel resizes never move an annotation (only the
// view mapping changes). Thresholds that are naturally defined on screen (click vs.
// drag, hit tolerance) are passed in already converted to content pixels by the view.

enum MarkupTool: String, CaseIterable, Sendable {
    /// Large preview only: Live Text selection; the drawing layer passes clicks through.
    case select
    case box, arrow, note

    /// The tools the inline editor offers (it has no Live Text to select).
    static let drawingTools: [MarkupTool] = [.box, .arrow, .note]

    var draws: Bool { self != .select }

    var accessibilityName: String {
        switch self {
        case .select: return "Select text"
        case .box: return "Highlight box"
        case .arrow: return "Arrow"
        case .note: return "Text note"
        }
    }
}

enum MarkupColor: String, CaseIterable, Sendable {
    case red, yellow, green, blue

    /// sRGB components (macOS system palette).
    var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .red: return (1.0, 0.231, 0.188)
        case .yellow: return (1.0, 0.8, 0.0)
        case .green: return (0.204, 0.78, 0.349)
        case .blue: return (0.0, 0.478, 1.0)
        }
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        let c = components
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }

    /// Yellow is too light for white text — its label pills use dark text instead.
    var usesDarkLabelText: Bool { self == .yellow }

    var accessibilityName: String { rawValue.capitalized }

    /// The 1–4 key that selects this colour in the editor.
    var keyNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct MarkupAnnotation: Identifiable, Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case box(CGRect)
        case arrow(tail: CGPoint, head: CGPoint)
        /// Free-standing text pill; the point is the pill's top-left corner.
        case note(CGPoint)

        var isNote: Bool {
            if case .note = self { return true }
            return false
        }

        /// Boxes and notes carry text; arrows don't.
        var acceptsText: Bool {
            if case .arrow = self { return false }
            return true
        }
    }

    let id: UUID
    var shape: Shape
    var color: MarkupColor
    /// Box label or note text. Empty = no label (box) / discarded (note).
    var text: String

    init(id: UUID = UUID(), shape: Shape, color: MarkupColor, text: String = "") {
        self.id = id
        self.shape = shape
        self.color = color
        self.text = text
    }

    /// Whether this annotation renders a text pill at all.
    var hasPill: Bool {
        shape.isNote || (shape.acceptsText && !text.isEmpty)
    }
}

/// Style sizes in content pixels: fixed point-based base sizes × the image's pixel
/// density, so markup matches the screenshot's own UI weight on 1x and 2x captures
/// and stays stable while the crop is dragged.
struct MarkupMetrics: Equatable, Sendable {
    let scale: CGFloat

    init(densityScale: CGFloat) {
        scale = min(max(densityScale, 1), 4)
    }

    var strokeWidth: CGFloat { 3 * scale }
    var fontSize: CGFloat { 14 * scale }
    var pillPaddingX: CGFloat { 7 * scale }
    var pillPaddingY: CGFloat { 4 * scale }
    var pillCornerRadius: CGFloat { 5 * scale }
    /// Gap between a box and its attached label pill.
    var labelGap: CGFloat { 4 * scale }
    var arrowShaftWidth: CGFloat { 4 * scale }
    var arrowHeadLength: CGFloat { 16 * scale }
    var arrowHeadHalfWidth: CGFloat { 8 * scale }
    /// Box interior tint opacity — the graph underneath stays readable.
    static let boxFillAlpha: CGFloat = 0.22

    /// Labels wrap at ~60% of the visible width (never narrower than a few words),
    /// but never wider than the visible region itself, so a small crop wraps the
    /// label instead of clipping it.
    func maxLabelWidth(in bounds: CGRect) -> CGFloat {
        min(max(bounds.width * 0.6, 120 * scale), bounds.width)
    }
}

enum ImageMarkup {

    // MARK: - Drag classification

    /// A gesture whose larger axis moved less than `threshold` is a click, not a drag.
    static func isClick(from start: CGPoint, to end: CGPoint, threshold: CGFloat) -> Bool {
        max(abs(end.x - start.x), abs(end.y - start.y)) < threshold
    }

    /// The rect spanned by a drag in any direction, clamped to `bounds`.
    static func rect(from start: CGPoint, to end: CGPoint, clampedTo bounds: CGRect) -> CGRect {
        let raw = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        let clamped = raw.intersection(bounds)
        return clamped.isNull ? .zero : clamped
    }

    /// True when a drawn shape would render as nothing — a box collapsed to a line or
    /// an arrow shorter than `minimumLength` (content pixels). Checked on the
    /// committed, edge-clamped geometry: a drag can move on screen yet clamp to a
    /// single edge, and an invisible shape must not turn a crop-only save into a
    /// save-as-new-item.
    static func isDegenerate(_ shape: MarkupAnnotation.Shape, minimumLength: CGFloat) -> Bool {
        switch shape {
        case .box(let rect):
            return rect.width < 1 || rect.height < 1
        case .arrow(let tail, let head):
            return hypot(head.x - tail.x, head.y - tail.y) < minimumLength
        case .note:
            return false
        }
    }

    // MARK: - Label text and moving notes

    /// Label text as committed: outer whitespace and blank lines trimmed, line
    /// breaks the user typed inside the text kept.
    static func normalizedLabel(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A note dragged by `delta` (content pixels), kept so its whole pill of
    /// `pillSize` stays inside `bounds` (the visible crop). Clamping the anchor to
    /// where the pill can actually be drawn means there's no dead zone where the
    /// pointer moves but the note doesn't. Other shapes don't move — they are
    /// redrawn instead.
    static func moved(
        _ annotation: MarkupAnnotation,
        by delta: CGSize,
        within bounds: CGRect,
        pillSize: CGSize = .zero
    ) -> MarkupAnnotation {
        guard case .note(let point) = annotation.shape else { return annotation }
        var moved = annotation
        moved.shape = .note(clamp(
            CGPoint(x: point.x + delta.width, y: point.y + delta.height),
            size: pillSize,
            to: bounds
        ))
        return moved
    }

    // MARK: - Label placement

    /// Pill rect for a box label: just above the box, below it when there is no room
    /// above, inside the box's top when neither fits — always clamped to `bounds`
    /// (the current crop), so the comment survives the crop on save.
    static func boxLabelRect(box: CGRect, pillSize: CGSize, bounds: CGRect, gap: CGFloat) -> CGRect {
        let above = box.minY - gap - pillSize.height
        let below = box.maxY + gap
        let y: CGFloat
        if above >= bounds.minY {
            y = above
        } else if below + pillSize.height <= bounds.maxY {
            y = below
        } else {
            y = max(box.minY, bounds.minY) + gap
        }
        let origin = clamp(CGPoint(x: box.minX, y: y), size: pillSize, to: bounds)
        return CGRect(origin: origin, size: pillSize)
    }

    /// Pill rect for a free-standing note anchored at `point`, clamped to `bounds`.
    static func noteRect(at point: CGPoint, pillSize: CGSize, bounds: CGRect) -> CGRect {
        CGRect(origin: clamp(point, size: pillSize, to: bounds), size: pillSize)
    }

    /// Keep a rect of `size` inside `bounds`, pinning to the top-left edge when it
    /// is larger than the bounds.
    private static func clamp(_ origin: CGPoint, size: CGSize, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: max(bounds.minX, min(origin.x, bounds.maxX - size.width)),
            y: max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        )
    }

    // MARK: - Arrow geometry

    /// The filled arrowhead triangle (tip, left, right) and the point where the shaft
    /// should end so its round cap never pokes past the head. The head shrinks on
    /// very short arrows so it never exceeds ~60% of the arrow's length.
    static func arrowHead(tail: CGPoint, head: CGPoint, metrics: MarkupMetrics)
        -> (tip: CGPoint, left: CGPoint, right: CGPoint, shaftEnd: CGPoint) {
        let dx = head.x - tail.x
        let dy = head.y - tail.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return (head, head, head, head) }
        let ux = dx / length, uy = dy / length
        let headLength = min(metrics.arrowHeadLength, length * 0.6)
        let halfWidth = metrics.arrowHeadHalfWidth * (headLength / metrics.arrowHeadLength)
        let base = CGPoint(x: head.x - ux * headLength, y: head.y - uy * headLength)
        // Perpendicular (-uy, ux).
        let left = CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth)
        let right = CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        return (head, left, right, base)
    }

    // MARK: - Hit testing

    /// The topmost annotation under `point`, or nil. A box is hit only on a band
    /// around its border or on its label pill — its interior stays free for drawing
    /// inside it and placing notes. `pillRects` maps annotation id → laid-out pill.
    static func hitTest(
        _ point: CGPoint,
        annotations: [MarkupAnnotation],
        pillRects: [UUID: CGRect],
        tolerance: CGFloat
    ) -> UUID? {
        for annotation in annotations.reversed() {
            if let pill = pillRects[annotation.id], pill.contains(point) {
                return annotation.id
            }
            switch annotation.shape {
            case .box(let rect):
                let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
                let inner = rect.insetBy(dx: tolerance, dy: tolerance)
                if outer.contains(point) && !inner.contains(point) {
                    return annotation.id
                }
            case .arrow(let tail, let head):
                if distance(from: point, toSegment: tail, head) <= tolerance {
                    return annotation.id
                }
            case .note:
                break // hit via its pill above
            }
        }
        return nil
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
