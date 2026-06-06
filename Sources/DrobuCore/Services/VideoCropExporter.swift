import AVFoundation
import CoreMedia
import Foundation

/// Houses the video save branch decision AND both export paths so `VideoTrimView`
/// only has to call one entry point and manage `isExporting` / error UI state.
///
/// Two paths:
/// - **Passthrough** (trim-only / no crop): `AVAssetExportPresetPassthrough`, lossless,
///   identical to the original trim export. `videoComposition` is ignored by passthrough.
/// - **Composition re-encode** (crop applied): builds an `AVMutableVideoComposition`
///   whose `renderSize` is the (even-rounded) crop size and a layer transform that
///   translates the cropped region's top-left to the output origin, then re-encodes
///   with `AVAssetExportPresetHighestQuality`.
///
/// The branch decision is exposed as a pure function (`needsReencode`) so it is unit
/// tested directly. All `AVMutable*` objects are constructed and consumed inside
/// `export(...)` — they are not Sendable and must never be stored in `@MainActor` state;
/// the function is designed to be called from a `Task.detached` capturing only Sendable
/// inputs (URLs, `CMTimeRange`, `CGRect`).
enum VideoCropExporter {

    enum ExportError: Error {
        case noVideoTrack
        case sessionCreationFailed
        case exportFailed(String)
    }

    /// Pure branch decision: a crop that is nil or full-frame stays on the lossless
    /// passthrough path (R11); any real crop forces the composition re-encode.
    ///
    /// `cropRect` is `nil` when the caller decided there is no crop. When non-nil it is
    /// the (already even-rounded) crop rect in content pixels, top-left origin. A caller
    /// must never pass a full-frame rect here — `CropGeometry.isFullFrame` is the gate —
    /// but we still treat a rect matching `contentSize` as passthrough defensively.
    static func needsReencode(cropRect: CGRect?, contentSize: CGSize? = nil) -> Bool {
        guard let cropRect else { return false }
        if let contentSize,
           cropRect.origin == .zero,
           cropRect.width == contentSize.width,
           cropRect.height == contentSize.height {
            return false
        }
        return true
    }

    /// Single export entry point.
    ///
    /// - Parameters:
    ///   - sourceURL: the source `.mp4`.
    ///   - outputURL: temp destination `.mp4` (born `0o600` via the umask wrap).
    ///   - trimRange: time range to keep, or `nil` for the full duration.
    ///   - cropRect: crop in content pixels (top-left origin, even-rounded by the caller),
    ///     or `nil` for no crop (→ passthrough).
    static func export(
        from sourceURL: URL,
        to outputURL: URL,
        trimRange: CMTimeRange?,
        cropRect: CGRect?
    ) async throws {
        // file-permission-hardening: any file the export session creates is born 0o600.
        let oldMask = umask(0o077)
        defer { umask(oldMask) }

        if let cropRect {
            try await exportCropped(from: sourceURL, to: outputURL, trimRange: trimRange, cropRect: cropRect)
        } else {
            try await exportPassthrough(from: sourceURL, to: outputURL, trimRange: trimRange)
        }
    }

    // MARK: - Passthrough (trim-only / no crop)

    private static func exportPassthrough(
        from sourceURL: URL,
        to outputURL: URL,
        trimRange: CMTimeRange?
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.sessionCreationFailed
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        if let trimRange {
            session.timeRange = trimRange
        }

        await session.export()

        guard session.status == .completed else {
            let reason = session.status == .cancelled
                ? "Export cancelled by system"
                : (session.error?.localizedDescription ?? "Unknown error")
            throw ExportError.exportFailed(reason)
        }
    }

    // MARK: - Composition re-encode (crop)

    private static func exportCropped(
        from sourceURL: URL,
        to outputURL: URL,
        trimRange: CMTimeRange?,
        cropRect: CGRect
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)

        // Async track + property loads — never read these synchronously (deprecated + blocking).
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let (preferredTransform, nominalFrameRate) = try await track.load(
            .preferredTransform, .nominalFrameRate
        )
        let assetDuration = try await asset.load(.duration)

        // Even-round defensively: the caller passes an already-even rect, but floor to
        // even here too — odd H.264 dimensions fail or produce a garbage edge row/column.
        let renderWidth = max(2, (cropRect.width / 2).rounded(.down) * 2)
        let renderHeight = max(2, (cropRect.height / 2).rounded(.down) * 2)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: renderWidth, height: renderHeight)

        // frameDuration from the track's nominal frame rate; fall back to 30 fps when
        // the rate reports 0 (some tracks don't expose a nominal rate).
        let fps = nominalFrameRate > 0 ? Int32(nominalFrameRate.rounded()) : 30
        composition.frameDuration = CMTime(value: 1, timescale: max(1, fps))

        // One instruction spanning the FULL asset duration — the export session's
        // timeRange does the trimming. A narrower instruction range causes blank frames.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Composition space is TOP-LEFT origin per the SDK header docs: identity puts the
        // frame's top-left at the output's top-left, positive translation moves right/down.
        // The crop rect from CropGeometry is also top-left, so translating by the negative
        // crop origin slides the cropped region's top-left to (0,0). The orientation test
        // (VideoCropExporterTests) verifies this against real pixel content; no Y-flip
        // correction was required.
        let transform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        )
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        // Passthrough ignores videoComposition entirely; HighestQuality honors it.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionCreationFailed
        }
        session.videoComposition = composition
        session.outputURL = outputURL
        session.outputFileType = .mp4
        if let trimRange {
            session.timeRange = trimRange
        }

        await session.export()

        guard session.status == .completed else {
            let reason = session.status == .cancelled
                ? "Export cancelled by system"
                : (session.error?.localizedDescription ?? "Unknown error")
            throw ExportError.exportFailed(reason)
        }
    }
}
