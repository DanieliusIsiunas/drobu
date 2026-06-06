import AVFoundation
import CoreMedia
import SwiftUI

/// Composition view for video trim + crop editing: player + crop overlay + timeline
/// scrubber + duration info. Mirrors GIFTrimView structure but uses time-based trimming
/// with AVAssetExportSession.
///
/// CRITICAL INVARIANT: the panel must stay visible for the entire export — `isExporting`
/// is true the whole time and there is deliberately NO panel-closing behavior on
/// save-initiation. Cleanup deferral is gated solely on panel visibility, and that is the
/// only thing stopping the hourly age-cleanup/orphan scan from deleting the source
/// `videos/<hash>.mp4` mid-read. `onSave` is invoked only after the export completes.
struct VideoTrimView: View {
    let url: URL
    let onSave: (URL) -> Void    // trimmed/cropped video temp file URL
    let onDiscard: () -> Void

    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var currentTime: Double = 0
    @State private var isLoaded = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    // Seeded from the track's true pixel size once the asset loads. ScreenCaptureKit
    // captures are upright, so naturalSize is the display size (top-left crop space).
    @State private var cropGeometry = CropGeometry(contentWidth: 0, contentHeight: 0)

    var body: some View {
        VStack(spacing: 0) {
            if isLoaded && duration > 0 {
                ZStack {
                    VideoTrimPlayerView(
                        url: url,
                        startTime: startTime,
                        endTime: endTime,
                        currentTime: $currentTime,
                        // Cmd+Return / Esc are swallowed while exporting (no-op). Otherwise
                        // save runs (or retries after an error) and discard exits.
                        onSave: { save() },
                        onDiscard: { discard() }
                    )
                    CropOverlayView(geometry: $cropGeometry, isInteractionEnabled: !isExporting)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

                VideoTimelineScrubberWithLabel(
                    duration: duration,
                    startTime: $startTime,
                    endTime: $endTime,
                    currentTime: currentTime
                )

                trimInfoBar
            } else if isExporting {
                ProgressView("Saving…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadDuration()
        }
    }

    private var trimInfoBar: some View {
        Group {
            let trimmed = endTime - startTime
            HStack {
                if isExporting {
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

                if trimmed < duration - 0.1 {
                    let m1 = Int(trimmed) / 60
                    let s1 = Int(trimmed) % 60
                    let m2 = Int(duration) / 60
                    let s2 = Int(duration) % 60
                    Text(String(format: "%d:%02d (was %d:%02d)", m1, s1, m2, s2))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    let m = Int(duration) / 60
                    let s = Int(duration) % 60
                    Text(String(format: "%d:%02d", m, s))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func loadDuration() {
        Task {
            let asset = AVURLAsset(url: url)
            // Duration and track list are independent reads — load them in parallel
            // so the "Loading video…" spinner lasts one round-trip, not two.
            async let durationLoad = asset.load(.duration)
            async let tracksLoad = asset.loadTracks(withMediaType: .video)
            let dur = try? await durationLoad.seconds
            // The video track's natural (pixel) size seeds the crop geometry.
            var naturalSize: CGSize = .zero
            do {
                if let track = try await tracksLoad.first {
                    naturalSize = try await track.load(.naturalSize)
                } else {
                    Log.error("VideoTrimView: no video track — crop disabled for this asset")
                }
            } catch {
                Log.error("VideoTrimView: failed to load track natural size: \(error)")
            }
            await MainActor.run {
                duration = dur ?? 0
                endTime = duration
                if naturalSize.width > 0, naturalSize.height > 0 {
                    cropGeometry = CropGeometry(
                        contentWidth: Int(naturalSize.width.rounded()),
                        contentHeight: Int(naturalSize.height.rounded())
                    )
                }
                isLoaded = true
            }
        }
    }

    private func discard() {
        guard !isExporting else { return }
        onDiscard()
    }

    /// Save path: decide passthrough vs re-encode, then export off the main actor.
    private func save() {
        guard !isExporting else { return }

        // Clear any prior error — Cmd+Return after a failure is a retry.
        errorMessage = nil

        // Branch decision delegated to the exporter's tested pure function; the
        // contentWidth guard keeps a failed asset load (0×0 geometry) on passthrough.
        let cropped = cropGeometry.contentWidth > 0 && VideoCropExporter.needsReencode(
            cropRect: cropGeometry.isFullFrame ? nil : cropGeometry.evenRoundedCropRect,
            contentSize: CGSize(width: cropGeometry.contentWidth, height: cropGeometry.contentHeight)
        )
        let trimmed = (endTime - startTime) < duration - 0.1

        // Untouched crop + untouched trim → save behaves exactly as today (no-op).
        if !cropped && !trimmed {
            onDiscard()
            return
        }

        isExporting = true

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mp4")

        let sourceURL = url
        // Trim range passed only when actually trimming; nil keeps the full duration.
        let trimRange: CMTimeRange? = trimmed
            ? CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 600),
                end: CMTime(seconds: endTime, preferredTimescale: 600)
            )
            : nil
        // Caller passes the already even-rounded rect; nil keeps passthrough.
        let cropRect: CGRect? = cropped ? cropGeometry.evenRoundedCropRect : nil

        Task.detached {
            do {
                try await VideoCropExporter.export(
                    from: sourceURL,
                    to: tempURL,
                    trimRange: trimRange,
                    cropRect: cropRect
                )
                await MainActor.run {
                    isExporting = false
                    onSave(tempURL)
                }
            } catch {
                Log.error("VideoTrimView: export failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run {
                    isExporting = false
                    errorMessage = "Save failed — try again"
                }
            }
        }
    }
}
