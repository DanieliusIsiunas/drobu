import CoreGraphics
import Testing
@testable import DrobuCore

@Suite("CropGeometry")
struct CropGeometryTests {

    // MARK: - Initial state and full-frame sentinel

    @Test func initialCropIsFullFrame() {
        let geo = CropGeometry(contentWidth: 100, contentHeight: 80)
        #expect(geo.cropRect == CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(geo.isFullFrame)
    }

    @Test func onePixelDragBreaksFullFrame() {
        var geo = CropGeometry(contentWidth: 100, contentHeight: 80)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 1, y: 0))
        #expect(!geo.isFullFrame)
        #expect(geo.cropRect.minX == 1)
    }

    @Test func outwardReadjustRestoresFullFrame() {
        var geo = CropGeometry(contentWidth: 100, contentHeight: 80)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 30, y: 0))
        geo.drag(edge: .top, toContentPoint: CGPoint(x: 0, y: 25))
        #expect(!geo.isFullFrame)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 0, y: 0))
        geo.drag(edge: .top, toContentPoint: CGPoint(x: 0, y: 0))
        #expect(geo.isFullFrame)
    }

    // MARK: - Minimum-size clamping (AE3)

    @Test func dragClampsAtMinimumSize() {
        var geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        // Covers AE3: dragging past the minimum stops at exactly 20.
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 95, y: 0))
        #expect(geo.cropRect.width == 20)
        #expect(geo.cropRect.minX == 80)
        #expect(geo.readoutText == "20 × 100")

        geo.drag(edge: .bottom, toContentPoint: CGPoint(x: 0, y: 3))
        #expect(geo.cropRect.height == 20)
    }

    @Test func dragClampsToContentBounds() {
        var geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: -50, y: 0))
        #expect(geo.cropRect.minX == 0)
        geo.drag(edge: .right, toContentPoint: CGPoint(x: 250, y: 0))
        #expect(geo.cropRect.maxX == 100)
        geo.drag(edge: .top, toContentPoint: CGPoint(x: 0, y: -10))
        #expect(geo.cropRect.minY == 0)
        geo.drag(edge: .bottom, toContentPoint: CGPoint(x: 0, y: 500))
        #expect(geo.cropRect.maxY == 100)
        #expect(geo.isFullFrame)
    }

    @Test func dragRoundsToWholePixels() {
        var geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 10.4, y: 0))
        #expect(geo.cropRect.minX == 10)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 10.6, y: 0))
        #expect(geo.cropRect.minX == 11)
    }

    // MARK: - Too-small content

    @Test(arguments: [(20, 20), (20, 1000), (1000, 20), (15, 15)])
    func tooSmallContentDisablesCropping(dims: (Int, Int)) {
        var geo = CropGeometry(contentWidth: dims.0, contentHeight: dims.1)
        #expect(!geo.isCroppable)
        #expect(geo.readoutText.contains("already at minimum"))

        // Drags are no-ops and hit-testing finds no edge.
        let before = geo.cropRect
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 5, y: 0))
        #expect(geo.cropRect == before)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: fitted.minX, y: fitted.midY), fittedRect: fitted, slop: 10) == nil)
    }

    // MARK: - Aspect-fit mapping

    @Test func fittedRectCentersAndScales() {
        let geo = CropGeometry(contentWidth: 200, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        #expect(fitted == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func fittedRectHandlesDegenerateSizes() {
        #expect(CropGeometry.fittedRect(contentSize: .zero, in: CGSize(width: 100, height: 100)) == .zero)
        #expect(CropGeometry.fittedRect(contentSize: CGSize(width: 10, height: 10), in: .zero) == .zero)
    }

    @Test func contentPointMapsThroughFitScale() {
        let geo = CropGeometry(contentWidth: 200, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        // Center of the displayed frame maps to the content center.
        let p = geo.contentPoint(fromViewPoint: CGPoint(x: 50, y: 50), fittedRect: fitted)
        #expect(p == CGPoint(x: 100, y: 50))
    }

    @Test func contentPointAtOneToOneScaleIsIdentity() {
        let geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        let p = geo.contentPoint(fromViewPoint: CGPoint(x: 42, y: 17), fittedRect: fitted)
        #expect(p == CGPoint(x: 42, y: 17))
    }

    @Test func letterboxClicksClampToContentEdge() {
        let geo = CropGeometry(contentWidth: 200, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100)) // (0, 25, 100, 50)
        // Click above the displayed frame, inside the letterbox margin.
        let p = geo.contentPoint(fromViewPoint: CGPoint(x: 50, y: 10), fittedRect: fitted)
        #expect(p == CGPoint(x: 100, y: 0))
    }

    @Test func retinaScaleMapsToTruePixels() {
        // 2x-origin media: 2000px content shown in a 1000pt frame.
        let geo = CropGeometry(contentWidth: 2000, contentHeight: 2000)
        let fitted = geo.fittedRect(in: CGSize(width: 1000, height: 1000))
        let p = geo.contentPoint(fromViewPoint: CGPoint(x: 250, y: 250), fittedRect: fitted)
        #expect(p == CGPoint(x: 500, y: 500))
    }

    @Test func resizeInvariance() {
        var geo = CropGeometry(contentWidth: 200, contentHeight: 100)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 40, y: 0))
        let before = geo.cropRect

        // The mapping recomputes per container; the content-pixel crop rect never moves.
        let small = geo.viewCropRect(fittedRect: geo.fittedRect(in: CGSize(width: 100, height: 100)))
        let large = geo.viewCropRect(fittedRect: geo.fittedRect(in: CGSize(width: 400, height: 400)))
        #expect(small != large)
        #expect(geo.cropRect == before)

        // Round trip: the view rect's corner maps back to the crop's content corner.
        let fitted = geo.fittedRect(in: CGSize(width: 400, height: 400))
        let viewRect = geo.viewCropRect(fittedRect: fitted)
        let corner = geo.contentPoint(fromViewPoint: viewRect.origin, fittedRect: fitted)
        #expect(abs(corner.x - geo.cropRect.minX) < 0.001)
        #expect(abs(corner.y - geo.cropRect.minY) < 0.001)
    }

    // MARK: - Edge hit testing

    @Test func nearestEdgePicksWithinSlop() {
        let geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 2, y: 50), fittedRect: fitted, slop: 8) == .left)
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 97, y: 50), fittedRect: fitted, slop: 8) == .right)
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 50, y: 3), fittedRect: fitted, slop: 8) == .top)
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 50, y: 96), fittedRect: fitted, slop: 8) == .bottom)
    }

    @Test func nearestEdgeIgnoresBeyondSlop() {
        let geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 50, y: 50), fittedRect: fitted, slop: 8) == nil)
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 20, y: 50), fittedRect: fitted, slop: 8) == nil)
    }

    @Test func cornerTieBreaksDeterministically() {
        let geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        // Exact corner: left and top are equidistant — declaration order wins.
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 0, y: 0), fittedRect: fitted, slop: 8) == .left)
    }

    @Test func nearestEdgeTracksMovedCropRect() {
        var geo = CropGeometry(contentWidth: 100, contentHeight: 100)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 40, y: 0))
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100))
        // The left edge now sits at x=40 in view space.
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 41, y: 50), fittedRect: fitted, slop: 8) == .left)
        #expect(geo.nearestEdge(atViewPoint: CGPoint(x: 2, y: 50), fittedRect: fitted, slop: 8) == nil)
    }

    // MARK: - Even rounding (video render size)

    @Test func evenRoundingFloorsOddDimensions() {
        var geo = CropGeometry(contentWidth: 1000, contentHeight: 1000)
        geo.drag(edge: .right, toContentPoint: CGPoint(x: 641, y: 0))
        geo.drag(edge: .bottom, toContentPoint: CGPoint(x: 0, y: 479))
        #expect(geo.cropRect.width == 641)
        #expect(geo.cropRect.height == 479)
        let even = geo.evenRoundedCropRect
        #expect(even.width == 640)
        #expect(even.height == 478)
    }

    @Test func evenRoundingLeavesEvenDimensionsAlone() {
        var geo = CropGeometry(contentWidth: 1000, contentHeight: 1000)
        geo.drag(edge: .right, toContentPoint: CGPoint(x: 640, y: 0))
        let even = geo.evenRoundedCropRect
        #expect(even.width == 640)
        #expect(even.height == 1000)
    }

    // MARK: - View crop rect

    @Test func viewCropRectMapsBackToViewSpace() {
        var geo = CropGeometry(contentWidth: 200, contentHeight: 100)
        geo.drag(edge: .left, toContentPoint: CGPoint(x: 100, y: 0))
        let fitted = geo.fittedRect(in: CGSize(width: 100, height: 100)) // (0, 25, 100, 50)
        let viewRect = geo.viewCropRect(fittedRect: fitted)
        #expect(viewRect == CGRect(x: 50, y: 25, width: 50, height: 50))
    }
}
