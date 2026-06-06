import CoreGraphics
import Foundation
import Testing
@testable import DrobuCore

@Suite("GIFFrameEngine crop")
struct GIFFrameEngineTests {

    // MARK: - Helpers

    /// Build a solid-color RGBA CGImage of the given pixel size.
    private static func solidImage(
        width: Int,
        height: Int,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGImage {
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
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Build N solid frames at 40×30 with the given delays.
    private static func makeFrames(delays: [Double]) -> [GIFFrame] {
        delays.enumerated().map { index, delay in
            let shade = CGFloat(index) / CGFloat(max(1, delays.count))
            return GIFFrame(
                image: solidImage(width: 40, height: 30, red: shade, green: 0.2, blue: 0.8),
                delay: delay
            )
        }
    }

    /// Round-trip a frame list through GIF encode + extract.
    private static func roundTrip(_ frames: [GIFFrame]) -> [GIFFrame]? {
        guard let data = GIFFrameEngine.encodeFrames(frames) else { return nil }
        let extracted = GIFFrameEngine.extractFrames(from: data)
        return extracted.isEmpty ? nil : extracted
    }

    /// Encoded GIF bytes for the given frame delays — shared with other suites that
    /// need real GIF data (e.g., ClipboardRecordTests' updateGifData tests).
    static func makeGIFData(delays: [Double]) -> Data? {
        GIFFrameEngine.encodeFrames(makeFrames(delays: delays))
    }

    // MARK: - AE5: trim slice → crop → encode → re-extract

    @Test func trimSliceThenCropPreservesDelaysAndDimensions() throws {
        // 5 frames, centisecond-safe delays (>= 0.1 so the GIF decoder won't clamp).
        let frames = Self.makeFrames(delays: [0.1, 0.2, 0.3, 0.4, 0.5])

        // Trim-slice to frames 1...3 (the middle three), as the view does.
        let sliced = Array(frames[1...3])

        // Crop each surviving frame to (5, 5, 20, 20).
        let cropped = try #require(
            GIFFrameEngine.cropFrames(sliced, to: CGRect(x: 5, y: 5, width: 20, height: 20))
        )

        // Encode and re-extract — this is what actually ships to the pasteboard.
        let extracted = try #require(Self.roundTrip(cropped))

        #expect(extracted.count == 3)
        for frame in extracted {
            #expect(frame.image.width == 20)
            #expect(frame.image.height == 20)
        }

        // Delays from the sliced middle frames: 0.2, 0.3, 0.4 (tolerance for GIF
        // centisecond storage).
        let expectedDelays = [0.2, 0.3, 0.4]
        for (frame, expected) in zip(extracted, expectedDelays) {
            #expect(abs(frame.delay - expected) <= 0.02)
        }
    }

    // MARK: - Clamping behavior

    @Test func cropPartiallyOutOfBoundsClampsToIntersection() throws {
        let frames = Self.makeFrames(delays: [0.1, 0.1])
        // Frames are 40×30. A rect starting at (30, 20) with size 20×20 extends past
        // both edges → intersection is (30, 20, 10, 10).
        let cropped = try #require(
            GIFFrameEngine.cropFrames(frames, to: CGRect(x: 30, y: 20, width: 20, height: 20))
        )
        #expect(cropped.count == 2)
        for frame in cropped {
            #expect(frame.image.width == 10)
            #expect(frame.image.height == 10)
        }
    }

    @Test func cropFullyOutsideReturnsNil() {
        let frames = Self.makeFrames(delays: [0.1, 0.1])
        // Frames are 40×30; a rect entirely beyond the right edge has no intersection.
        let result = GIFFrameEngine.cropFrames(frames, to: CGRect(x: 100, y: 100, width: 20, height: 20))
        #expect(result == nil)
    }

    @Test func cropFullFrameReturnsOriginalDimensions() throws {
        let frames = Self.makeFrames(delays: [0.1, 0.2, 0.3])
        let cropped = try #require(
            GIFFrameEngine.cropFrames(frames, to: CGRect(x: 0, y: 0, width: 40, height: 30))
        )
        #expect(cropped.count == 3)
        for frame in cropped {
            #expect(frame.image.width == 40)
            #expect(frame.image.height == 30)
        }
    }

    // MARK: - Encoded canvas equals crop size

    @Test func encodedCroppedCanvasEqualsCropSizeForEveryFrame() throws {
        let frames = Self.makeFrames(delays: [0.1, 0.1, 0.1, 0.1])
        let cropped = try #require(
            GIFFrameEngine.cropFrames(frames, to: CGRect(x: 8, y: 4, width: 24, height: 22))
        )
        let extracted = try #require(Self.roundTrip(cropped))
        #expect(extracted.count == 4)
        for frame in extracted {
            #expect(frame.image.width == 24)
            #expect(frame.image.height == 22)
        }
    }

    @Test func cropEmptyFramesReturnsNil() {
        #expect(GIFFrameEngine.cropFrames([], to: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
    }
}
