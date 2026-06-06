import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DrobuCore

@Suite("ImageCrop")
struct ImageCropTests {

    // MARK: - Helpers

    /// Build a solid-color PNG of the given pixel size via CGContext + CGImageDestination.
    static func makePNG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, cgImage, nil)
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let image = ImageCrop.decodeBitmap(from: data) else { return nil }
        return (image.width, image.height)
    }

    // MARK: - decodeBitmap (gate helper)

    @Test func decodeBitmapReturnsImageForRealPNG() {
        let png = Self.makePNG(width: 64, height: 48)
        let decoded = ImageCrop.decodeBitmap(from: png)
        #expect(decoded != nil)
        #expect(decoded?.width == 64)
        #expect(decoded?.height == 48)
    }

    @Test func decodeBitmapReturnsNilForArbitraryData() {
        let text = Data("this is not an image".utf8)
        #expect(ImageCrop.decodeBitmap(from: text) == nil)
    }

    // MARK: - isBitmapData (header-only hot-path gate)

    @Test func isBitmapDataAcceptsRealPNG() {
        let png = Self.makePNG(width: 64, height: 48)
        #expect(ImageCrop.isBitmapData(png))
    }

    @Test func isBitmapDataRejectsArbitraryData() {
        let text = Data("this is not an image".utf8)
        #expect(!ImageCrop.isBitmapData(text))
        #expect(!ImageCrop.isBitmapData(Data()))
    }

    // MARK: - Crop round-trip

    @Test func cropRoundTripProducesExactCropDimensions() {
        let png = Self.makePNG(width: 100, height: 80)
        let cropped = ImageCrop.cropAndEncodePNG(png, to: CGRect(x: 10, y: 10, width: 40, height: 30))
        #expect(cropped != nil)

        let dims = Self.pixelDimensions(of: cropped!)
        #expect(dims?.width == 40)
        #expect(dims?.height == 30)
    }
}
