import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import DrobuCore

/// Integration tests for `VideoCropExporter`.
///
/// AVFoundation in tests is fine — real-dependency testing is the repo convention.
/// The orientation test (`cropTopLeftQuadrantIsWhite` / `cropBottomLeftQuadrantIsDark`)
/// is the plan's mandated verification spike for the composition Y-direction: it exports
/// a real crop and samples actual pixel content to prove the crop took the TOP-LEFT
/// region (not a Y-flipped bottom-left).
@Suite("VideoCropExporter")
struct VideoCropExporterTests {

    // MARK: - Test fixtures

    /// Synthesize a tiny H.264 MP4 where the TOP-LEFT quadrant (in display orientation,
    /// top-left origin) is WHITE and the rest is DARK. Pixel content makes orientation
    /// detectable: a correct top-left crop is bright, a Y-flipped one is dark.
    ///
    /// - Returns: the temp file URL of the written clip.
    static func makeQuadrantClip(
        width: Int = 320,
        height: Int = 240,
        frameCount: Int = 8,
        fps: Int32 = 10
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-test-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let buffer = try makeQuadrantPixelBuffer(width: width, height: height)

        for frame in 0..<frameCount {
            // Wait until the input can accept more data.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: fps)
            adaptor.append(buffer, withPresentationTime: pts)
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            throw NSError(
                domain: "VideoCropExporterTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "writer failed"]
            )
        }
        return url
    }

    /// One BGRA pixel buffer: top-left quadrant white, the rest near-black.
    /// CGContext is bottom-left origin, so "top" = high y; we fill the top-left visual
    /// quadrant at y in [height/2, height).
    static func makeQuadrantPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "VideoCropExporterTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "VideoCropExporterTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no base address"])
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw NSError(domain: "VideoCropExporterTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext failed"])
        }

        // Dark fill everywhere.
        ctx.setFillColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // White top-left visual quadrant (CGContext top = high y).
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))

        return buffer
    }

    /// Mean luma (0...1) of a frame sampled from the output, in display orientation.
    static func sampleMeanLuma(of url: URL, at seconds: Double = 0.2) throws -> Double {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil
        )

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        let count = width * height
        for i in 0..<count {
            let r = Double(pixels[i * 4 + 0])
            let g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        }
        return total / Double(count)
    }

    static func trackNaturalSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return .zero
        }
        return try await track.load(.naturalSize)
    }

    // MARK: - Branch decision (AE1, pure function)

    @Test func nilCropChoosesPassthrough() {
        #expect(VideoCropExporter.needsReencode(cropRect: nil) == false)
    }

    @Test func fullFrameCropChoosesPassthrough() {
        let size = CGSize(width: 320, height: 240)
        let full = CGRect(origin: .zero, size: size)
        #expect(VideoCropExporter.needsReencode(cropRect: full, contentSize: size) == false)
    }

    @Test func nonFullCropChoosesReencode() {
        let size = CGSize(width: 320, height: 240)
        let cropped = CGRect(x: 0, y: 0, width: 160, height: 120)
        #expect(VideoCropExporter.needsReencode(cropRect: cropped, contentSize: size) == true)
        // Without a content size, any non-nil rect is treated as a real crop.
        #expect(VideoCropExporter.needsReencode(cropRect: cropped) == true)
    }

    // MARK: - Crop output size + orientation (AE2)

    @Test func cropTopLeftQuadrantIsWhite() async throws {
        let source = try await Self.makeQuadrantClip()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        // Crop the TOP-LEFT quadrant — the white region.
        try await VideoCropExporter.export(
            from: source, to: output, trimRange: nil,
            cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)
        )

        let size = try await Self.trackNaturalSize(of: output)
        #expect(size == CGSize(width: 160, height: 120))

        let luma = try Self.sampleMeanLuma(of: output)
        // Predominantly white proves the crop took the TOP-LEFT region (no Y-flip bug).
        #expect(luma > 0.7)
    }

    @Test func cropBottomLeftQuadrantIsDark() async throws {
        let source = try await Self.makeQuadrantClip()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        // Crop the BOTTOM-LEFT quadrant — the dark region.
        try await VideoCropExporter.export(
            from: source, to: output, trimRange: nil,
            cropRect: CGRect(x: 0, y: 120, width: 160, height: 120)
        )

        let size = try await Self.trackNaturalSize(of: output)
        #expect(size == CGSize(width: 160, height: 120))

        let luma = try Self.sampleMeanLuma(of: output)
        // Dark proves the bottom-left region was taken (and that top-left is not mirrored down).
        #expect(luma < 0.2)
    }

    // MARK: - Odd crop dimensions

    @Test func oddCropDimensionsRoundedDownToEven() async throws {
        let source = try await Self.makeQuadrantClip()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        // Odd 161×121 → floored to even 160×120 by the exporter.
        try await VideoCropExporter.export(
            from: source, to: output, trimRange: nil,
            cropRect: CGRect(x: 0, y: 0, width: 161, height: 121)
        )

        let size = try await Self.trackNaturalSize(of: output)
        #expect(size == CGSize(width: 160, height: 120))
    }

    // MARK: - Trim + crop combined

    @Test func trimAndCropCombined() async throws {
        // 20 frames at 10fps → 2.0s source.
        let source = try await Self.makeQuadrantClip(frameCount: 20, fps: 10)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        // Trim to the middle ~half: 0.5s..1.5s ≈ 1.0s.
        let trim = CMTimeRange(
            start: CMTime(seconds: 0.5, preferredTimescale: 600),
            end: CMTime(seconds: 1.5, preferredTimescale: 600)
        )
        try await VideoCropExporter.export(
            from: source, to: output, trimRange: trim,
            cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)
        )

        let size = try await Self.trackNaturalSize(of: output)
        #expect(size == CGSize(width: 160, height: 120))

        let outDuration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(outDuration - 1.0) < 0.3)
    }

    // MARK: - Error path

    @Test func exportFromMissingSourceThrows() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        await #expect(throws: (any Error).self) {
            try await VideoCropExporter.export(
                from: missing, to: output, trimRange: nil,
                cropRect: CGRect(x: 0, y: 0, width: 160, height: 120)
            )
        }
    }
}
