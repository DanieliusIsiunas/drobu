import CoreGraphics
import CoreText
import Foundation

/// Draws image markup into any `CGContext` whose user space is **content pixels with a
/// top-left origin**. The editor overlay (a flipped NSView scaled to its aspect-fit
/// rect) and the save path (a bitmap context flipped after the image is drawn) call
/// the same `draw`, so the overlay is a faithful preview of the saved PNG by
/// construction. Text is laid out with CoreText so this stays a pure CG function.
enum MarkupRenderer {

    // MARK: - Text layout

    private struct PillText {
        let framesetter: CTFramesetter
        let textSize: CGSize
        let pillSize: CGSize
    }

    private static func pillText(_ text: String, color: MarkupColor, metrics: MarkupMetrics, bounds: CGRect) -> PillText {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, metrics.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, metrics.fontSize, nil)
        let textColor = color.usesDarkLabelText
            ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxTextWidth = metrics.maxLabelWidth(in: bounds) - metrics.pillPaddingX * 2
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), nil
        )
        // +1 slack: a frame exactly the suggested size can drop its last line to rounding.
        let textSize = CGSize(
            width: max(ceil(suggested.width) + 1, metrics.fontSize * 0.5),
            height: max(ceil(suggested.height) + 1, ceil(metrics.fontSize * 1.25))
        )
        let pillSize = CGSize(
            width: textSize.width + metrics.pillPaddingX * 2,
            height: textSize.height + metrics.pillPaddingY * 2
        )
        return PillText(framesetter: framesetter, textSize: textSize, pillSize: pillSize)
    }

    /// The laid-out pill rect for an annotation, or nil when it shows no pill.
    /// `bounds` is the visible region (the current crop) the pill is clamped to.
    static func pillRect(for annotation: MarkupAnnotation, metrics: MarkupMetrics, bounds: CGRect) -> CGRect? {
        guard annotation.hasPill else { return nil }
        let size = pillText(annotation.text, color: annotation.color, metrics: metrics, bounds: bounds).pillSize
        return pillRect(for: annotation, pillSize: size, metrics: metrics, bounds: bounds)
    }

    private static func pillRect(for annotation: MarkupAnnotation, pillSize: CGSize, metrics: MarkupMetrics, bounds: CGRect) -> CGRect? {
        // A shape cropped out entirely keeps no label: clamping its pill into the
        // crop would leave an orphaned comment on the saved image.
        switch annotation.shape {
        case .box(let rect):
            guard rect.intersects(bounds) else { return nil }
            return ImageMarkup.boxLabelRect(box: rect, pillSize: pillSize, bounds: bounds, gap: metrics.labelGap)
        case .note(let point):
            guard point.x >= bounds.minX, point.x <= bounds.maxX,
                  point.y >= bounds.minY, point.y <= bounds.maxY else { return nil }
            return ImageMarkup.noteRect(at: point, pillSize: pillSize, bounds: bounds)
        case .arrow:
            return nil
        }
    }

    static func pillRects(for annotations: [MarkupAnnotation], metrics: MarkupMetrics, bounds: CGRect) -> [UUID: CGRect] {
        var rects: [UUID: CGRect] = [:]
        for annotation in annotations {
            if let rect = pillRect(for: annotation, metrics: metrics, bounds: bounds) {
                rects[annotation.id] = rect
            }
        }
        return rects
    }

    // MARK: - Drawing

    /// Draw every annotation in order (later ones on top). `hidingPillOf` suppresses
    /// one annotation's pill — the editor hides it while its inline text field is open.
    static func draw(
        _ annotations: [MarkupAnnotation],
        in context: CGContext,
        metrics: MarkupMetrics,
        bounds: CGRect,
        hidingPillOf hiddenID: UUID? = nil
    ) {
        for annotation in annotations {
            draw(annotation, in: context, metrics: metrics, bounds: bounds, showPill: annotation.id != hiddenID)
        }
    }

    static func draw(
        _ annotation: MarkupAnnotation,
        in context: CGContext,
        metrics: MarkupMetrics,
        bounds: CGRect,
        showPill: Bool = true
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        let solid = annotation.color.cgColor()

        switch annotation.shape {
        case .box(let rect):
            context.setFillColor(annotation.color.cgColor(alpha: MarkupMetrics.boxFillAlpha))
            context.fill(rect)
            context.setStrokeColor(solid)
            context.setLineWidth(metrics.strokeWidth)
            context.stroke(rect)
        case .arrow(let tail, let head):
            let geo = ImageMarkup.arrowHead(tail: tail, head: head, metrics: metrics)
            context.setStrokeColor(solid)
            context.setLineWidth(metrics.arrowShaftWidth)
            context.setLineCap(.round)
            context.move(to: tail)
            context.addLine(to: geo.shaftEnd)
            context.strokePath()
            context.setFillColor(solid)
            context.move(to: geo.tip)
            context.addLine(to: geo.left)
            context.addLine(to: geo.right)
            context.closePath()
            context.fillPath()
        case .note:
            break // a note is only its pill
        }

        guard showPill, annotation.hasPill else { return }
        let text = pillText(annotation.text, color: annotation.color, metrics: metrics, bounds: bounds)
        guard let pill = pillRect(for: annotation, pillSize: text.pillSize, metrics: metrics, bounds: bounds) else { return }

        let radius = min(metrics.pillCornerRadius, pill.height / 2)
        context.setFillColor(solid)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()

        let textRect = CGRect(
            x: pill.minX + metrics.pillPaddingX,
            y: pill.minY + metrics.pillPaddingY,
            width: text.textSize.width,
            height: text.textSize.height
        )
        drawText(text.framesetter, in: textRect, context: context)
    }

    /// CoreText lays frames out y-up. In the top-left (y-down) user space, flipping
    /// only the text matrix makes glyphs upright but stacks wrapped lines bottom-up,
    /// so flip the whole space locally around the text rect's centre line instead.
    private static func drawText(_ framesetter: CTFramesetter, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil
        )
        CTFrameDraw(frame, context)
    }

    // MARK: - Flatten, crop, encode

    /// Composite `annotations` onto `image` and encode the `crop` region (content
    /// pixels, top-left) as PNG. The bitmap is only crop-sized: the image is drawn
    /// offset so just the crop lands in it. Nil on any CG failure.
    static func renderPNG(image: CGImage, annotations: [MarkupAnnotation], crop: CGRect, metrics: MarkupMetrics) -> Data? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let region = crop.intersection(full).integral
        guard !region.isEmpty else { return nil }
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw the image in the context's native y-up space FIRST — flipping before
        // this would save the screenshot upside down — then flip for the markup.
        // In y-up space the crop's bottom edge sits at full.height - region.maxY.
        context.draw(image, in: full.offsetBy(dx: -region.minX, dy: -(full.height - region.maxY)))
        context.translateBy(x: -region.minX, y: region.maxY)
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, metrics: metrics, bounds: region)

        guard let flattened = context.makeImage() else { return nil }
        return ImageCrop.encodePNG(flattened)
    }
}
