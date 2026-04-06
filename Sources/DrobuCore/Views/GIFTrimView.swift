import SwiftUI

/// Composition view for GIF trim editing: frame player + timeline scrubber.
/// Manages shared state between player and scrubber.
struct GIFTrimView: View {
    let data: Data
    let onSave: (Data) -> Void
    let onDiscard: () -> Void

    @State private var frames: [GIFFrame] = []
    @State private var startFrame = 0
    @State private var endFrame = 0
    @State private var currentFrame = 0
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoaded && !frames.isEmpty {
                // Frame player (fills available space, handles Cmd+Return / Escape)
                GIFTrimPlayerView(
                    frames: frames,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    currentFrame: $currentFrame,
                    onSave: { saveTrimmedGIF() },
                    onDiscard: { onDiscard() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)

                // Timeline scrubber (fixed height at bottom)
                TimelineScrubberWithLabel(
                    frameCount: frames.count,
                    startFrame: $startFrame,
                    endFrame: $endFrame,
                    currentFrame: currentFrame
                )

                // Trim info + duration comparison
                trimInfoBar
            } else {
                ProgressView("Extracting frames...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadFrames()
        }
    }

    private var trimInfoBar: some View {
        Group {
            if !frames.isEmpty {
                let selectedCount = endFrame - startFrame + 1
                let originalDuration = frames.reduce(0.0) { $0 + $1.delay }
                let trimmedDuration = frames[startFrame...endFrame].reduce(0.0) { $0 + $1.delay }

                HStack {
                    Text("\(selectedCount) of \(frames.count) frames")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if selectedCount < frames.count {
                        Text(String(format: "%.1fs (was %.1fs)", trimmedDuration, originalDuration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "%.1fs", originalDuration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
    }

    private func loadFrames() {
        let extracted = GIFFrameEngine.extractFrames(from: data)
        frames = extracted
        endFrame = max(0, extracted.count - 1)
        isLoaded = true
    }

    private func saveTrimmedGIF() {
        guard !frames.isEmpty, startFrame <= endFrame else { return }
        let selectedFrames = Array(frames[startFrame...endFrame])
        if let trimmedData = GIFFrameEngine.encodeFrames(selectedFrames) {
            onSave(trimmedData)
        }
    }
}
