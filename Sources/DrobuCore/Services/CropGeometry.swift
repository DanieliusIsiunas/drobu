import CoreGraphics

/// Pure geometry for the crop editing overlay.
///
/// All crop state lives in **content pixels** with a **top-left origin** — the same
/// space `CGImage.cropping(to:)` uses, and the space the dimension readout reports.
/// View-space conversions go through an aspect-fit rect supplied by the host, so the
/// crop rect itself is invariant under panel resizes (only the mapping changes).
///
/// Coordinates are kept integral: every drag rounds to whole pixels before clamping,
/// which keeps `isFullFrame` an exact integer comparison (the sentinel that gates the
/// video passthrough-vs-re-encode branch).
struct CropGeometry: Equatable {
    let contentWidth: Int
    let contentHeight: Int
    private(set) var cropRect: CGRect

    /// Minimum crop size per axis, in content pixels (mirrors the capture-time 20×20 floor).
    static let minimumCropSize = 20

    enum Edge: CaseIterable {
        case left, right, top, bottom
    }

    init(contentWidth: Int, contentHeight: Int) {
        self.contentWidth = max(0, contentWidth)
        self.contentHeight = max(0, contentHeight)
        self.cropRect = CGRect(x: 0, y: 0, width: self.contentWidth, height: self.contentHeight)
    }

    var contentBounds: CGRect {
        CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    }

    /// True when the crop rect equals the full content bounds (integer-exact).
    /// Sole guard for "save behaves exactly as today" — never re-encode when true.
    var isFullFrame: Bool {
        cropRect == contentBounds
    }

    /// False when either content dimension is at or below the minimum — edges are
    /// disabled and the overlay shows the too-small readout instead.
    var isCroppable: Bool {
        contentWidth > Self.minimumCropSize && contentHeight > Self.minimumCropSize
    }

    /// Dimension readout in content pixels.
    var readoutText: String {
        if !isCroppable {
            return "\(contentWidth) × \(contentHeight) px — already at minimum"
        }
        return "\(Int(cropRect.width)) × \(Int(cropRect.height))"
    }

    // MARK: - Aspect-fit mapping

    /// Centered aspect-fit rect for the given content size inside a container.
    /// Symmetric vertically, so the result is identical in flipped and unflipped spaces.
    static func fittedRect(contentSize: CGSize, in container: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }

    func fittedRect(in container: CGSize) -> CGRect {
        Self.fittedRect(
            contentSize: CGSize(width: contentWidth, height: contentHeight),
            in: container
        )
    }

    /// Convert a point in the host view's top-left-origin coordinates to content
    /// pixels, clamped to the content bounds (clicks in the letterbox margin clamp
    /// to the nearest content edge).
    func contentPoint(fromViewPoint point: CGPoint, fittedRect: CGRect) -> CGPoint {
        guard fittedRect.width > 0, fittedRect.height > 0 else { return .zero }
        let x = (point.x - fittedRect.minX) * CGFloat(contentWidth) / fittedRect.width
        let y = (point.y - fittedRect.minY) * CGFloat(contentHeight) / fittedRect.height
        return CGPoint(
            x: min(max(0, x), CGFloat(contentWidth)),
            y: min(max(0, y), CGFloat(contentHeight))
        )
    }

    /// The crop rect mapped into view coordinates for drawing.
    func viewCropRect(fittedRect: CGRect) -> CGRect {
        guard contentWidth > 0, contentHeight > 0 else { return .zero }
        let sx = fittedRect.width / CGFloat(contentWidth)
        let sy = fittedRect.height / CGFloat(contentHeight)
        return CGRect(
            x: fittedRect.minX + cropRect.minX * sx,
            y: fittedRect.minY + cropRect.minY * sy,
            width: cropRect.width * sx,
            height: cropRect.height * sy
        )
    }

    // MARK: - Hit testing

    /// The nearest crop edge within `slop` view-points of `point`, or nil.
    /// A corner click resolves to the closer edge; exact ties resolve in declaration
    /// order (left, right, top, bottom) — deterministic, not probabilistic.
    func nearestEdge(atViewPoint point: CGPoint, fittedRect: CGRect, slop: CGFloat) -> Edge? {
        guard isCroppable else { return nil }
        let rect = viewCropRect(fittedRect: fittedRect)
        let withinX = point.x >= rect.minX - slop && point.x <= rect.maxX + slop
        let withinY = point.y >= rect.minY - slop && point.y <= rect.maxY + slop

        let candidates: [(edge: Edge, distance: CGFloat, inSpan: Bool)] = [
            (.left, abs(point.x - rect.minX), withinY),
            (.right, abs(point.x - rect.maxX), withinY),
            (.top, abs(point.y - rect.minY), withinX),
            (.bottom, abs(point.y - rect.maxY), withinX),
        ]

        var best: (edge: Edge, distance: CGFloat)?
        for candidate in candidates {
            guard candidate.inSpan, candidate.distance <= slop else { continue }
            if best == nil || candidate.distance < best!.distance {
                best = (candidate.edge, candidate.distance)
            }
        }
        return best?.edge
    }

    // MARK: - Dragging

    /// Move `edge` to the given content-pixel position, rounding to whole pixels and
    /// clamping to the content bounds and the per-axis minimum. Edges re-adjust
    /// outward freely — dragging back out restores up to the full frame.
    mutating func drag(edge: Edge, toContentPoint point: CGPoint) {
        guard isCroppable else { return }
        let minSize = CGFloat(Self.minimumCropSize)

        switch edge {
        case .left:
            let x = min(max(0, point.x.rounded()), cropRect.maxX - minSize)
            cropRect = CGRect(x: x, y: cropRect.minY, width: cropRect.maxX - x, height: cropRect.height)
        case .right:
            let x = min(max(point.x.rounded(), cropRect.minX + minSize), CGFloat(contentWidth))
            cropRect = CGRect(x: cropRect.minX, y: cropRect.minY, width: x - cropRect.minX, height: cropRect.height)
        case .top:
            let y = min(max(0, point.y.rounded()), cropRect.maxY - minSize)
            cropRect = CGRect(x: cropRect.minX, y: y, width: cropRect.width, height: cropRect.maxY - y)
        case .bottom:
            let y = min(max(point.y.rounded(), cropRect.minY + minSize), CGFloat(contentHeight))
            cropRect = CGRect(x: cropRect.minX, y: cropRect.minY, width: cropRect.width, height: y - cropRect.minY)
        }
    }

    // MARK: - Output rects

    /// Crop rect with width/height floored to even integers — H.264 encoders require
    /// even dimensions (odd sizes fail or produce a garbage edge row/column).
    var evenRoundedCropRect: CGRect {
        CGRect(
            x: cropRect.minX,
            y: cropRect.minY,
            width: max(2, (cropRect.width / 2).rounded(.down) * 2),
            height: max(2, (cropRect.height / 2).rounded(.down) * 2)
        )
    }
}
