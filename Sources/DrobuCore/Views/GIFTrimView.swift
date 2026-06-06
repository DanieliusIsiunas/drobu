import SwiftUI

/// Composition view for GIF trim + crop editing: frame player + crop overlay + timeline scrubber.
/// Manages shared state between player, overlay, and scrubber.
struct GIFTrimView: View {
    let data: Data
    let onSave: (Data) -> Void
    let onDiscard: () -> Void

    @State private var frames: [GIFFrame] = []
    @State private var startFrame = 0
    @State private var endFrame = 0
    @State private var currentFrame = 0
    @State private var isLoaded = false

    @State private var cropGeometry = CropGeometry(contentWidth: 0, contentHeight: 0)
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoaded && !frames.isEmpty {
                // Frame player with the crop overlay layered on top. The overlay's
                // hitTest only claims clicks near a crop edge, so it is safe above the
                // player; the shared .frame/.padding keep the overlay's bounds matching
                // the player's so the aspect-fit math lines up.
                ZStack {
                    GIFTrimPlayerView(
                        frames: frames,
                        startFrame: startFrame,
                        endFrame: endFrame,
                        currentFrame: $currentFrame,
                        onSave: { saveTrimmedGIF() },
                        onDiscard: { discard() }
                    )
                    CropOverlayView(geometry: $cropGeometry, isInteractionEnabled: !isSaving)
                }
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

                // Trim info + duration comparison (or saving/error state)
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

    // Only reached from body's `isLoaded && !frames.isEmpty` branch.
    private var trimInfoBar: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                Spacer()
            } else {
                let selectedCount = endFrame - startFrame + 1
                let originalDuration = frames.reduce(0.0) { $0 + $1.delay }
                let trimmedDuration = frames[startFrame...endFrame].reduce(0.0) { $0 + $1.delay }

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
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func loadFrames() {
        let extracted = GIFFrameEngine.extractFrames(from: data)
        frames = extracted
        endFrame = max(0, extracted.count - 1)
        // Initialize crop geometry from the FIRST frame's true pixel size (never
        // NSImage.size, which reports points and under-reports Retina media).
        if let first = extracted.first {
            cropGeometry = CropGeometry(
                contentWidth: first.image.width,
                contentHeight: first.image.height
            )
        }
        isLoaded = true
    }

    private func discard() {
        guard !isSaving else { return }
        onDiscard()
    }

    private func saveTrimmedGIF() {
        guard !frames.isEmpty, startFrame <= endFrame, !isSaving else { return }
        let selectedFrames = Array(frames[startFrame...endFrame])
        let cropRect = cropGeometry.cropRect
        let isFullFrame = cropGeometry.isFullFrame

        isSaving = true
        errorMessage = nil

        // Slice is already done; crop (when not full-frame) + encode run off the main
        // actor. GIFFrame is Sendable, so capturing the sliced frames is safe.
        Task.detached {
            let framesToEncode: [GIFFrame]?
            if isFullFrame {
                framesToEncode = selectedFrames
            } else {
                framesToEncode = GIFFrameEngine.cropFrames(selectedFrames, to: cropRect)
            }

            guard let framesToEncode else {
                Log.error("GIFTrimView: cropFrames returned nil")
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Save failed — try again"
                }
                return
            }

            guard let encoded = GIFFrameEngine.encodeFrames(framesToEncode) else {
                Log.error("GIFTrimView: encodeFrames returned nil")
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Save failed — try again"
                }
                return
            }

            await MainActor.run {
                isSaving = false
                onSave(encoded)
            }
        }
    }
}
