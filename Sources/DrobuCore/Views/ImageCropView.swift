import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Pure image-crop helpers, kept free of view state so the decode → crop → encode
/// pipeline is directly testable. `ImageCropView` uses these and adds only UI.
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

/// Crop-only inline editor for still images (Cmd+Right edit mode for `kindImage`).
///
/// Mirrors `GIFTrimView`'s layout: the image fills the available space aspect-fit, a
/// `CropOverlayView` draws the draggable crop edges on top, and an info bar at the
/// bottom shows the save/discard hints (plus saving / error states). Esc and
/// Cmd+Return are owned by an invisible first-responder NSView (the same pattern as
/// `GIFTrimPlayerView`) so keyboard handling matches the trim editors.
struct ImageCropView: View {
    let data: Data
    let onSave: (Data) -> Void
    let onDiscard: () -> Void

    @State private var cgImage: CGImage?
    @State private var cropGeometry = CropGeometry(contentWidth: 0, contentHeight: 0)
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let cgImage {
                ZStack {
                    // Invisible key handler in the background so it never blocks the overlay.
                    ImageCropKeyView(
                        onSave: { save() },
                        onDiscard: { discard() }
                    )

                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    CropOverlayView(geometry: $cropGeometry, isInteractionEnabled: !isSaving)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

                cropInfoBar
            } else {
                ProgressView("Loading image...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: decodeIfNeeded)
    }

    private var cropInfoBar: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text("\u{2318}\u{21A9} save  esc discard")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func decodeIfNeeded() {
        guard cgImage == nil else { return }
        guard let decoded = ImageCrop.decodeBitmap(from: data) else { return }
        cgImage = decoded
        // Initialise crop state from the TRUE pixel size (never NSImage.size, which is
        // in points and under-reports Retina media).
        cropGeometry = CropGeometry(contentWidth: decoded.width, contentHeight: decoded.height)
    }

    private func discard() {
        guard !isSaving else { return }
        onDiscard()
    }

    private func save() {
        guard !isSaving, let cgImage else { return }

        // Untouched crop → behave exactly like Esc: close, record untouched, no message.
        guard !cropGeometry.isFullFrame else {
            onDiscard()
            return
        }

        isSaving = true
        errorMessage = nil
        let rect = cropGeometry.cropRect

        Task.detached {
            let pngData = ImageCrop.cropAndEncodePNG(cgImage, to: rect)
            await MainActor.run {
                if let pngData {
                    onSave(pngData)
                } else {
                    Log.error("ImageCropView: crop/PNG encode failed")
                    isSaving = false
                    errorMessage = "Save failed — try again"
                }
            }
        }
    }
}

// MARK: - Invisible key handler

/// Transparent first-responder view hosting the shared `EditorKeyNSView` (Esc /
/// Cmd+Return contract). Placed in the ZStack background so it never intercepts
/// crop-edge clicks.
struct ImageCropKeyView: NSViewRepresentable {
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    func makeNSView(context: Context) -> EditorKeyNSView {
        let view = EditorKeyNSView()
        view.onSave = onSave
        view.onDiscard = onDiscard
        // Invisible utility view — not an accessibility element.
        view.setAccessibilityElement(false)

        // Acquire focus after layout (same pattern as GIFTrimPlayerView).
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: EditorKeyNSView, context: Context) {
        nsView.onSave = onSave
        nsView.onDiscard = onDiscard
    }
}
