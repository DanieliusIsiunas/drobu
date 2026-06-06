import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A single decoded GIF frame plus its on-screen duration.
///
/// `CGImage` carries the SDK's `Sendable` conformance, but the wrapper struct is not
/// implicitly `Sendable` under Swift 6 — the explicit one-word conformance lets
/// `[GIFFrame]` cross into `Task.detached` for off-main-actor crop+encode. (The
/// contents are genuinely Sendable, so never `@unchecked Sendable` here.)
struct GIFFrame: Sendable {
    let image: CGImage
    let delay: Double  // seconds
}

enum GIFFrameEngine {

    /// Extract all frames and their delays from GIF data.
    static func extractFrames(from data: Data) -> [GIFFrame] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        var frames: [GIFFrame] = []
        frames.reserveCapacity(count)

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            var delay: Double = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                     ?? gifProps[kCGImagePropertyGIFDelayTime as String] as? Double
                     ?? 0.1
                // GIF spec: delays < 0.02s are often treated as 0.1s by browsers
                if delay < 0.02 { delay = 0.1 }
            }
            frames.append(GIFFrame(image: cgImage, delay: delay))
        }
        return frames
    }

    /// Encode a subset of frames back into GIF data.
    static func encodeFrames(_ frames: [GIFFrame]) -> Data? {
        guard !frames.isEmpty else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { return nil }

        // File-level GIF properties: infinite loop
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // Add each frame with its delay
        for frame in frames {
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: frame.delay
                ]
            ]
            CGImageDestinationAddImage(destination, frame.image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Crop every frame to `rect` (content pixels, top-left origin), preserving each
    /// frame's delay. The rect is integral-clamped to each frame's own pixel bounds
    /// before cropping — `CGImage.cropping(to:)` clamps internally too, but we clamp
    /// explicitly so the result is predictable. The cropped images are lazy no-copy
    /// views into the originals, which is fine because they flow straight into encode.
    ///
    /// Returns nil if the clamped rect is empty/outside any frame, or any frame fails
    /// to crop — so the caller can keep the user in edit mode rather than emit a
    /// corrupt GIF.
    static func cropFrames(_ frames: [GIFFrame], to rect: CGRect) -> [GIFFrame]? {
        guard !frames.isEmpty else { return nil }

        let integralRect = rect.integral
        var cropped: [GIFFrame] = []
        cropped.reserveCapacity(frames.count)

        for frame in frames {
            let bounds = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
            let clamped = integralRect.intersection(bounds)
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
            guard let croppedImage = frame.image.cropping(to: clamped) else { return nil }
            cropped.append(GIFFrame(image: croppedImage, delay: frame.delay))
        }
        return cropped
    }

    /// Encode GIF from compressed frame data (JPEG) with per-frame delays.
    /// Decompresses one frame at a time to minimize peak memory during screen capture encoding.
    static func encodeFromCompressedFrames(_ frames: [(data: Data, delay: Double)]) -> Data? {
        guard !frames.isEmpty else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { return nil }

        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        for frame in frames {
            guard let source = CGImageSourceCreateWithData(frame.data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: frame.delay
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
