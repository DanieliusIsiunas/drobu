import Testing
import CoreGraphics
import Foundation
@testable import DrobuCore

@Suite("MarkupRenderer")
struct MarkupRendererTests {

    let metrics = MarkupMetrics(densityScale: 1)

    // MARK: - Shapes

    @Test func boxTintsInsideAndLeavesOutsideUntouched() throws {
        let source = Self.solidImage(width: 200, height: 200, red: 0, green: 0, blue: 1)
        let box = MarkupAnnotation(shape: .box(CGRect(x: 50, y: 50, width: 100, height: 100)), color: .red)
        let out = try render(source, [box])

        let inside = out.pixel(x: 100, y: 100)
        #expect(inside.r > 0.15 && inside.b < 0.9) // blue tinted toward red
        #expect(out.pixel(x: 10, y: 10) == RGB(r: 0, g: 0, b: 1))
    }

    @Test func boxBorderIsFullySaturated() throws {
        let source = Self.solidImage(width: 200, height: 200, red: 0, green: 0, blue: 1)
        let box = MarkupAnnotation(shape: .box(CGRect(x: 50, y: 50, width: 100, height: 100)), color: .red)
        let border = try render(source, [box]).pixel(x: 50, y: 100)
        #expect(border.r > 0.95 && border.b < 0.25)
    }

    @Test func arrowColoursItsShaftOnly() throws {
        let source = Self.solidImage(width: 200, height: 200, red: 0, green: 0, blue: 1)
        let arrow = MarkupAnnotation(
            shape: .arrow(tail: CGPoint(x: 20, y: 100), head: CGPoint(x: 180, y: 100)), color: .red
        )
        let out = try render(source, [arrow])
        #expect(out.pixel(x: 60, y: 100).r > 0.95)
        #expect(out.pixel(x: 60, y: 80) == RGB(r: 0, g: 0, b: 1))
    }

    @Test func noteDrawsPillAndText() throws {
        let source = Self.solidImage(width: 300, height: 200, red: 0, green: 0, blue: 1)
        let note = MarkupAnnotation(shape: .note(CGPoint(x: 40, y: 40)), color: .red, text: "Cost spike")
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let pill = try #require(MarkupRenderer.pillRect(for: note, metrics: metrics, bounds: bounds))
        let out = try render(source, [note])

        // Padding area of the pill is the fill colour.
        let fill = out.pixel(x: Int(pill.minX) + 2, y: Int(pill.midY))
        #expect(fill.r > 0.95 && fill.b < 0.25)
        // Some white text ink exists inside the pill.
        #expect(out.count(in: pill) { $0.isNearWhite } > 10)
    }

    // MARK: - Orientation (the two flipped-context traps)

    @Test func backgroundKeepsItsOrientation() throws {
        let source = Self.splitImage(width: 100, height: 100) // red top, blue bottom
        let box = MarkupAnnotation(shape: .box(CGRect(x: 80, y: 80, width: 10, height: 10)), color: .green)
        let out = try render(source, [box])
        #expect(out.pixel(x: 50, y: 2) == RGB(r: 1, g: 0, b: 0))
        #expect(out.pixel(x: 50, y: 97) == RGB(r: 0, g: 0, b: 1))
    }

    @Test func wrappedLabelLinesKeepTheirOrder() throws {
        let source = Self.solidImage(width: 400, height: 300, red: 0, green: 0, blue: 1)
        // Long first line, one narrow glyph on the second line.
        let note = MarkupAnnotation(shape: .note(CGPoint(x: 20, y: 20)), color: .red, text: "MMMMMM\nI")
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let pill = try #require(MarkupRenderer.pillRect(for: note, metrics: metrics, bounds: bounds))
        let out = try render(source, [note])

        // Right part of the pill: only the long first line has ink there.
        let right = CGRect(x: pill.minX + 30, y: pill.minY, width: pill.width - 30, height: pill.height)
        let upper = CGRect(x: right.minX, y: right.minY, width: right.width, height: right.height / 2)
        let lower = CGRect(x: right.minX, y: right.midY, width: right.width, height: right.height / 2)
        // The short second line has no ink this far right, so the lower half must be
        // (nearly) empty; reversed line order puts the long line there instead.
        let upperInk = out.count(in: upper) { $0.isNearWhite }
        let lowerInk = out.count(in: lower) { $0.isNearWhite }
        #expect(upperInk > 50)
        #expect(lowerInk < upperInk / 10)
    }

    // MARK: - Crop

    @Test func cropAppliesAfterMarkup() throws {
        let source = Self.solidImage(width: 200, height: 200, red: 0, green: 0, blue: 1)
        let box = MarkupAnnotation(shape: .box(CGRect(x: 120, y: 120, width: 40, height: 40)), color: .red)
        let crop = CGRect(x: 100, y: 100, width: 100, height: 100)
        let out = try render(source, [box], crop: crop)
        #expect(out.width == 100 && out.height == 100)
        #expect(out.pixel(x: 20, y: 40).r > 0.95) // left border, crop-relative
    }

    @Test func labelAtCropTopSurvivesCrop() throws {
        let source = Self.solidImage(width: 200, height: 200, red: 0, green: 0, blue: 1)
        let crop = CGRect(x: 0, y: 100, width: 200, height: 100)
        let box = MarkupAnnotation(shape: .box(CGRect(x: 20, y: 100, width: 60, height: 30)), color: .red, text: "Here")
        let pill = try #require(MarkupRenderer.pillRect(for: box, metrics: metrics, bounds: crop))
        #expect(pill.minY > 130) // placed below the box, inside the crop

        let out = try render(source, [box], crop: crop)
        let fill = out.pixel(x: Int(pill.minX) + 2, y: Int(pill.midY - crop.minY))
        #expect(fill.r > 0.95 && fill.b < 0.25)
    }

    @Test func annotationOutsideCropLeavesCropUnchanged() throws {
        let source = Self.splitImage(width: 100, height: 100)
        let crop = CGRect(x: 0, y: 50, width: 100, height: 50)
        let outside = MarkupAnnotation(shape: .box(CGRect(x: 10, y: 5, width: 20, height: 20)), color: .green)
        let marked = try render(source, [outside], crop: crop)
        let plain = try Bitmap(png: #require(ImageCrop.cropAndEncodePNG(source, to: crop)))
        #expect(marked.pixels == plain.pixels)
    }

    // MARK: - Helpers

    private func render(_ image: CGImage, _ annotations: [MarkupAnnotation], crop: CGRect? = nil) throws -> Bitmap {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let png = try #require(MarkupRenderer.renderPNG(
            image: image, annotations: annotations, crop: crop ?? full, metrics: metrics
        ))
        return try Bitmap(png: png)
    }

    static func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Red top half, blue bottom half (as seen top-down).
    static func splitImage(width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)
        let half = CGFloat(height) / 2
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: half)) // CG y-up: bottom
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: half, width: CGFloat(width), height: half)) // top
        return context.makeImage()!
    }

    static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}

struct RGB: Equatable {
    let r: CGFloat, g: CGFloat, b: CGFloat

    var isNearWhite: Bool { r > 0.85 && g > 0.85 && b > 0.85 }

    /// Tolerant comparison — 8-bit quantisation and colour management round a little.
    static func == (lhs: RGB, rhs: RGB) -> Bool {
        abs(lhs.r - rhs.r) < 0.03 && abs(lhs.g - rhs.g) < 0.03 && abs(lhs.b - rhs.b) < 0.03
    }
}

/// Decoded RGBA8 pixels addressed top-down, for pixel assertions.
struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(png: Data) throws {
        let image = try #require(ImageCrop.decodeBitmap(from: png))
        let w = image.width, h = image.height
        let context = MarkupRendererTests.makeContext(width: w, height: h)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try #require(context.data)
        width = w
        height = h
        pixels = Array(UnsafeRawBufferPointer(start: data, count: w * h * 4))
    }

    /// `y` counts from the top. CGContext memory is already top-row-first.
    func pixel(x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: CGFloat(pixels[i]) / 255, g: CGFloat(pixels[i + 1]) / 255, b: CGFloat(pixels[i + 2]) / 255)
    }

    func count(in rect: CGRect, where predicate: (RGB) -> Bool) -> Int {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var n = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) where predicate(pixel(x: x, y: y)) {
                n += 1
            }
        }
        return n
    }
}
