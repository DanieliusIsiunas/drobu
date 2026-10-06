import Testing
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import DrobuCore

@Suite("ImageMarkup")
struct ImageMarkupTests {

    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let pill = CGSize(width: 120, height: 30)
    let gap: CGFloat = 4

    // MARK: - Metrics

    @Test func metricsScaleWithDensity() {
        let x1 = MarkupMetrics(densityScale: 1)
        let x2 = MarkupMetrics(densityScale: 2)
        #expect(x2.strokeWidth == x1.strokeWidth * 2)
        #expect(x2.fontSize == x1.fontSize * 2)
    }

    @Test func metricsClampDensity() {
        #expect(MarkupMetrics(densityScale: 0.25).scale == 1)
        #expect(MarkupMetrics(densityScale: 12).scale == 4)
    }

    @Test func densityScaleReadsDPIAbove72() {
        #expect(ImageCrop.pixelDensityScale(of: Self.makePNG(dpi: 144)) == 2)
    }

    @Test func densityScaleIsUnknownAt72() {
        #expect(ImageCrop.pixelDensityScale(of: Self.makePNG(dpi: 72)) == nil)
    }

    @Test func labelWidthNeverExceedsVisibleWidth() {
        let metrics = MarkupMetrics(densityScale: 2)
        let smallCrop = CGRect(x: 0, y: 0, width: 90, height: 400)
        #expect(metrics.maxLabelWidth(in: smallCrop) == 90)
        #expect(metrics.maxLabelWidth(in: bounds) == 600) // 60% of a wide view
    }

    // MARK: - Label placement

    @Test func labelSitsAboveBoxWhenThereIsRoom() {
        let box = CGRect(x: 100, y: 200, width: 50, height: 100)
        let rect = ImageMarkup.boxLabelRect(box: box, pillSize: pill, bounds: bounds, gap: gap)
        #expect(rect.maxY == box.minY - gap)
        #expect(rect.minX == box.minX)
    }

    @Test func labelMovesBelowWhenBoxTouchesTop() {
        let box = CGRect(x: 100, y: 0, width: 50, height: 100)
        let rect = ImageMarkup.boxLabelRect(box: box, pillSize: pill, bounds: bounds, gap: gap)
        #expect(rect.minY == box.maxY + gap)
    }

    @Test func labelFallsInsideWhenBoxSpansFullHeight() {
        let box = CGRect(x: 100, y: 0, width: 50, height: 600)
        let rect = ImageMarkup.boxLabelRect(box: box, pillSize: pill, bounds: bounds, gap: gap)
        #expect(rect.minY == gap)
        #expect(bounds.contains(rect))
    }

    @Test func labelClampsHorizontallyAtRightEdge() {
        let box = CGRect(x: 980, y: 200, width: 20, height: 100)
        let rect = ImageMarkup.boxLabelRect(box: box, pillSize: pill, bounds: bounds, gap: gap)
        #expect(rect.maxX == bounds.maxX)
    }

    @Test func labelRespectsCropBoundsNotImageBounds() {
        // Image has room above the box, but the crop starts at the box's top edge.
        let crop = CGRect(x: 0, y: 300, width: 1000, height: 300)
        let box = CGRect(x: 100, y: 300, width: 50, height: 100)
        let rect = ImageMarkup.boxLabelRect(box: box, pillSize: pill, bounds: crop, gap: gap)
        #expect(rect.minY == box.maxY + gap)
        #expect(crop.contains(rect))
    }

    @Test func noteClampsInsideBounds() {
        let rect = ImageMarkup.noteRect(at: CGPoint(x: 990, y: 590), pillSize: pill, bounds: bounds)
        #expect(bounds.contains(rect))
    }

    // MARK: - Drag classification

    @Test func dragRectNormalisesDirection() {
        let a = ImageMarkup.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 220), clampedTo: bounds)
        let b = ImageMarkup.rect(from: CGPoint(x: 110, y: 220), to: CGPoint(x: 10, y: 20), clampedTo: bounds)
        #expect(a == b)
        #expect(a == CGRect(x: 10, y: 20, width: 100, height: 200))
    }

    @Test func dragRectClampsToBounds() {
        let r = ImageMarkup.rect(from: CGPoint(x: -50, y: -50), to: CGPoint(x: 2000, y: 100), clampedTo: bounds)
        #expect(r == CGRect(x: 0, y: 0, width: 1000, height: 100))
    }

    @Test(arguments: [
        // threshold models a 4pt click radius at two display zooms (content px per pt)
        (CGFloat(4), CGFloat(3), true),
        (CGFloat(4), CGFloat(5), false),
        (CGFloat(40), CGFloat(30), true),
        (CGFloat(40), CGFloat(45), false),
    ])
    func clickThreshold(threshold: CGFloat, moved: CGFloat, isClick: Bool) {
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 100 + moved, y: 100)
        #expect(ImageMarkup.isClick(from: start, to: end, threshold: threshold) == isClick)
    }

    @Test(arguments: [
        (MarkupAnnotation.Shape.box(CGRect(x: 0, y: 10, width: 0, height: 80)), true),
        (MarkupAnnotation.Shape.box(CGRect(x: 0, y: 10, width: 30, height: 0.5)), true),
        (MarkupAnnotation.Shape.box(CGRect(x: 0, y: 10, width: 30, height: 40)), false),
        (MarkupAnnotation.Shape.arrow(tail: CGPoint(x: 0, y: 5), head: CGPoint(x: 0, y: 8)), true),
        (MarkupAnnotation.Shape.arrow(tail: CGPoint(x: 0, y: 5), head: CGPoint(x: 40, y: 5)), false),
    ])
    func degenerateShapes(shape: MarkupAnnotation.Shape, isDegenerate: Bool) {
        #expect(ImageMarkup.isDegenerate(shape, minimumLength: 4) == isDegenerate)
    }

    // MARK: - Label text and moving notes

    @Test func labelTextKeepsInnerLineBreaks() {
        #expect(ImageMarkup.normalizedLabel("  Cost spike\nafter resize \n\n") == "Cost spike\nafter resize")
        #expect(ImageMarkup.normalizedLabel(" \n \t") == "")
    }

    @Test func movingANoteShiftsItsAnchor() {
        let note = MarkupAnnotation(shape: .note(CGPoint(x: 100, y: 100)), color: .red, text: "Hi")
        let moved = ImageMarkup.moved(note, by: CGSize(width: 30, height: -20), within: bounds)
        #expect(moved.shape == .note(CGPoint(x: 130, y: 80)))
        #expect(moved.id == note.id && moved.text == "Hi")
    }

    @Test func movingANoteStaysInsideTheVisibleImage() {
        let note = MarkupAnnotation(shape: .note(CGPoint(x: 10, y: 10)), color: .red, text: "Hi")
        let moved = ImageMarkup.moved(note, by: CGSize(width: -500, height: 5000), within: bounds)
        #expect(moved.shape == .note(CGPoint(x: bounds.minX, y: bounds.maxY)))
    }

    @Test func movingANoteKeepsItsWholePillVisible() {
        // No dead zone: the anchor can't sit where the pill would be pushed back in.
        let note = MarkupAnnotation(shape: .note(CGPoint(x: 100, y: 100)), color: .red, text: "Hi")
        let pill = CGSize(width: 120, height: 30)
        let moved = ImageMarkup.moved(note, by: CGSize(width: 5000, height: 5000), within: bounds, pillSize: pill)
        #expect(moved.shape == .note(CGPoint(x: bounds.maxX - 120, y: bounds.maxY - 30)))
    }

    @Test func movingANoteRespectsAnOffsetCrop() {
        let crop = CGRect(x: 200, y: 100, width: 300, height: 200)
        let note = MarkupAnnotation(shape: .note(CGPoint(x: 250, y: 150)), color: .red, text: "Hi")
        let moved = ImageMarkup.moved(note, by: CGSize(width: -1000, height: -1000), within: crop, pillSize: CGSize(width: 50, height: 20))
        #expect(moved.shape == .note(CGPoint(x: 200, y: 100)))
    }

    @Test func onlyNotesMove() {
        let box = MarkupAnnotation(shape: .box(CGRect(x: 0, y: 0, width: 20, height: 20)), color: .red)
        #expect(ImageMarkup.moved(box, by: CGSize(width: 50, height: 50), within: bounds) == box)
    }

    // MARK: - Hit testing

    @Test func boxIsHitOnBorderNotInterior() {
        let box = MarkupAnnotation(shape: .box(CGRect(x: 100, y: 100, width: 200, height: 200)), color: .red)
        let onBorder = ImageMarkup.hitTest(CGPoint(x: 101, y: 200), annotations: [box], pillRects: [:], tolerance: 6)
        let inside = ImageMarkup.hitTest(CGPoint(x: 200, y: 200), annotations: [box], pillRects: [:], tolerance: 6)
        #expect(onBorder == box.id)
        #expect(inside == nil)
    }

    @Test func overlappingBordersReturnTopmost() {
        let lower = MarkupAnnotation(shape: .box(CGRect(x: 100, y: 100, width: 200, height: 200)), color: .red)
        let upper = MarkupAnnotation(shape: .box(CGRect(x: 100, y: 100, width: 100, height: 100)), color: .blue)
        let hit = ImageMarkup.hitTest(CGPoint(x: 100, y: 150), annotations: [lower, upper], pillRects: [:], tolerance: 6)
        #expect(hit == upper.id)
    }

    @Test func pillHitSelectsItsAnnotation() {
        let box = MarkupAnnotation(shape: .box(CGRect(x: 100, y: 100, width: 50, height: 50)), color: .red, text: "hi")
        let pillRect = CGRect(x: 100, y: 60, width: 80, height: 30)
        let hit = ImageMarkup.hitTest(CGPoint(x: 150, y: 70), annotations: [box], pillRects: [box.id: pillRect], tolerance: 6)
        #expect(hit == box.id)
    }

    @Test func arrowHitWithinToleranceOfShaft() {
        let arrow = MarkupAnnotation(shape: .arrow(tail: CGPoint(x: 0, y: 100), head: CGPoint(x: 400, y: 100)), color: .red)
        let near = ImageMarkup.hitTest(CGPoint(x: 200, y: 104), annotations: [arrow], pillRects: [:], tolerance: 6)
        let far = ImageMarkup.hitTest(CGPoint(x: 200, y: 140), annotations: [arrow], pillRects: [:], tolerance: 6)
        #expect(near == arrow.id)
        #expect(far == nil)
    }

    @Test func emptyCanvasHitsNothing() {
        #expect(ImageMarkup.hitTest(CGPoint(x: 5, y: 5), annotations: [], pillRects: [:], tolerance: 6) == nil)
    }

    // MARK: - Arrow geometry

    @Test func arrowheadSitsAtHeadAlongDirection() {
        let metrics = MarkupMetrics(densityScale: 1)
        let geo = ImageMarkup.arrowHead(tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 100, y: 0), metrics: metrics)
        #expect(geo.tip == CGPoint(x: 100, y: 0))
        #expect(geo.shaftEnd.x == 100 - metrics.arrowHeadLength)
        #expect(geo.left.x == geo.shaftEnd.x && geo.right.x == geo.shaftEnd.x)
        #expect(abs(geo.left.y - geo.right.y) == metrics.arrowHeadHalfWidth * 2)
    }

    @Test func arrowheadShrinksOnShortArrow() {
        let metrics = MarkupMetrics(densityScale: 1)
        let geo = ImageMarkup.arrowHead(tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 10, y: 0), metrics: metrics)
        #expect(geo.shaftEnd.x == 4) // head length capped at 60% of 10
    }

    // MARK: - Helpers

    static func makePNG(dpi: Double) -> Data {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }
}
