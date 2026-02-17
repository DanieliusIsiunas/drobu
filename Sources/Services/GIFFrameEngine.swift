import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFFrame {
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
}
