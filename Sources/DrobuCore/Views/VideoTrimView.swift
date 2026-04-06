import AVFoundation
import SwiftUI

/// Composition view for video trim editing: player + timeline scrubber + duration info.
/// Mirrors GIFTrimView structure but uses time-based trimming with AVAssetExportSession.
struct VideoTrimView: View {
    let url: URL
    let onSave: (URL) -> Void    // trimmed video temp file URL
    let onDiscard: () -> Void

    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var currentTime: Double = 0
    @State private var isLoaded = false
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoaded && duration > 0 {
                VideoTrimPlayerView(
                    url: url,
                    startTime: startTime,
                    endTime: endTime,
                    currentTime: $currentTime,
                    onSave: { exportTrimmed() },
                    onDiscard: { onDiscard() }
                )
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
                ProgressView("Exporting trimmed video...")
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
                    Text("Exporting...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\u{2318}\u{21A9} save  esc discard")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            let asset = AVAsset(url: url)
            let dur = try? await asset.load(.duration).seconds
            await MainActor.run {
                duration = dur ?? 0
                endTime = duration
                isLoaded = true
            }
        }
    }

    private func exportTrimmed() {
        guard !isExporting else { return }

        let trimmed = endTime - startTime
        // If selection is the full video, nothing to trim
        if trimmed >= duration - 0.1 {
            onDiscard()
            return
        }

        isExporting = true

        let asset = AVAsset(url: url)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let capturedStart = startTime
        let capturedEnd = endTime

        Task.detached {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                Log.error("VideoTrimView: failed to create export session")
                await MainActor.run { isExporting = false }
                return
            }

            session.outputURL = tempURL
            session.outputFileType = .mp4
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: capturedStart, preferredTimescale: 600),
                end: CMTime(seconds: capturedEnd, preferredTimescale: 600)
            )

            await session.export()

            if session.status == .completed {
                await MainActor.run {
                    isExporting = false
                    onSave(tempURL)
                }
            } else {
                let errorDesc = session.error?.localizedDescription ?? "Unknown error"
                Log.error("VideoTrimView: export failed: \(errorDesc)")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run { isExporting = false }
            }
        }
    }
}
