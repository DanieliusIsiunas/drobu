import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure image-crop helpers, kept free of view state so the decode → crop → encode
/// pipeline is directly testable. `ImageCropView` uses these and adds only UI.
/// Lives in Services/ alongside the other pure engines (`CropGeometry`,
/// `GIFFrameEngine`, `VideoCropExporter`).
enum ImageCrop {
    /// Decode the first bitmap frame of `data` to a `CGImage`.
    /// Returns nil for non-bitmap payloads (text, PDF-backed pasteboard data, etc.).
    static func decodeBitmap(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Header-only check that `data` is a decodable bitmap — the edit-mode gate.
    /// Runs on the Cmd+Right hot path, so it must never decode pixels
    /// (`decodeBitmap` allocates the full bitmap — megabytes for a Retina
    /// screenshot); reading container properties is enough to reject non-bitmap
    /// payloads, and `ImageCropView` handles a late decode failure gracefully.
    static func isBitmapData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
    }

    /// Decode `data`, crop to `rect` (top-left origin, content pixels — the
    /// `CropGeometry.cropRect` space), and re-encode as PNG. Returns nil if the data
    /// is not a decodable bitmap or the PNG encode fails. The crop rect is clamped to
    /// the image bounds defensively (`CGImage.cropping(to:)` is internally integral
    /// and clamped, but an out-of-bounds rect can return nil).
    static func cropAndEncodePNG(_ data: Data, to rect: CGRect) -> Data? {
        guard let cgImage = decodeBitmap(from: data) else { return nil }
        return cropAndEncodePNG(cgImage, to: rect)
    }

    /// Crop `cgImage` to `rect` and encode as PNG.
    static func cropAndEncodePNG(_ cgImage: CGImage, to rect: CGRect) -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clamped = rect.intersection(bounds).integral
        guard !clamped.isEmpty, let cropped = cgImage.cropping(to: clamped) else { return nil }
        return encodePNG(cropped)
    }

    /// Encode a `CGImage` to PNG `Data`.
    static func encodePNG(_ cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
