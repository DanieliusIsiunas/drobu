import AVFoundation
import AVKit
import SwiftUI

struct PreviewPanel: View {
    let item: ClipboardRecord?
    var selectionCount: Int = 1
    @Binding var isEditing: Bool
    @Binding var editingText: String
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onGifSave: ((Data) -> Void)?
    var onVideoSave: ((URL) -> Void)?
    var onCleanup: (() -> Void)?

    /// Character threshold for SwiftUI Text (fast for small strings).
    /// Above this, text is truncated; right-arrow enters edit mode for full content.
    private static let textPreviewLimit = 5_000

    var body: some View {
        VStack(spacing: 0) {
            if selectionCount > 1 {
                multiSelectSummary
            } else if let item = item {
                VStack(spacing: 0) {
                    previewContent(for: item)
                    Spacer(minLength: 0)
                    metadataBar(for: item)
                }
                .chromaSweepBorder(isActive: isEditing)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview Content

    @ViewBuilder
    private func previewContent(for item: ClipboardRecord) -> some View {
        switch item.kind {
        case ClipboardRecord.kindGif:
            gifPreview(for: item)
        case ClipboardRecord.kindImage:
            imagePreview(for: item)
        case ClipboardRecord.kindVideo:
            videoPreview(for: item)
        default:
            textPreview(for: item)
        }
    }

    @ViewBuilder
    private func textPreview(for item: ClipboardRecord) -> some View {
        if isEditing {
            EditableTextView(
                text: $editingText,
                onSave: onSave,
                onDiscard: onDiscard,
                onCleanup: onCleanup
            )
        } else {
            let text = item.plainText ?? ""
            let isTruncated = text.count > Self.textPreviewLimit
            let displayText = isTruncated ? String(text.prefix(Self.textPreviewLimit)) : text

            VStack(spacing: 0) {
                ScrollView {
                    Text(displayText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }

                if isTruncated {
                    Divider()

                    let formatted = ByteCountFormatter.string(
                        fromByteCount: Int64(text.utf8.count),
                        countStyle: .file
                    )
                    Text("Showing \(Self.textPreviewLimit.formatted()) of \(text.count.formatted()) chars (\(formatted))  \u{2192} to show full")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func imagePreview(for item: ClipboardRecord) -> some View {
        Group {
            if let data = item.imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("Unable to load image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func gifPreview(for item: ClipboardRecord) -> some View {
        if isEditing, let data = item.imageData {
            GIFTrimView(
                data: data,
                onSave: { trimmedData in
                    onGifSave?(trimmedData)
                },
                onDiscard: {
                    onDiscard?()
                }
            )
        } else if let data = item.imageData {
            AnimatedGIFView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        } else {
            VStack {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.quaternary)
                Text("Unable to load GIF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func videoPreview(for item: ClipboardRecord) -> some View {
        let url = ClipboardRecord.videoPath(for: item.contentHash)
        if isEditing, FileManager.default.fileExists(atPath: url.path) {
            VideoTrimView(
                url: url,
                onSave: { trimmedURL in onVideoSave?(trimmedURL) },
                onDiscard: { onDiscard?() }
            )
        } else if FileManager.default.fileExists(atPath: url.path) {
            InlineVideoPlayerView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let data = item.imageData, let nsImage = NSImage(data: data) {
            // Fallback: show thumbnail if video file is missing
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        } else {
            VStack {
                Image(systemName: "video.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.quaternary)
                Text("Video file not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Metadata Bar

    private func metadataBar(for item: ClipboardRecord) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if item.kind == ClipboardRecord.kindText {
                // Use editingText for live counts during editing, otherwise item text
                let displayText = isEditing ? editingText : (item.plainText ?? "")
                let words = displayText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                Text("\(words) words; \(displayText.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.kind == ClipboardRecord.kindGif, let data = item.imageData, let nsImage = NSImage(data: data) {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                let meta = ClipboardRecord.gifMetadata(from: data)
                let durationStr = meta.map { String(format: "%.1fs", $0.duration) } ?? ""
                let framesStr = meta.map { "\($0.frameCount) frames" } ?? ""
                let detailStr = ["\(w)x\(h)", sizeStr, durationStr, framesStr]
                    .filter { !$0.isEmpty }.joined(separator: " | ")
                Text(detailStr)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.kind == ClipboardRecord.kindVideo {
                let url = ClipboardRecord.videoPath(for: item.contentHash)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                if let thumb = item.imageData, let nsImage = NSImage(data: thumb) {
                    let w = Int(nsImage.size.width)
                    let h = Int(nsImage.size.height)
                    Text("\(w)x\(h) | \(sizeStr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(sizeStr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if item.kind == ClipboardRecord.kindImage, let data = item.imageData, let nsImage = NSImage(data: data) {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                Text("\(w)x\(h) (\(sizeStr))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Copied \(item.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Multi-Select Summary

    private var multiSelectSummary: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("\(selectionCount) items selected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Press Return to paste all")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "eye")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("Select an item to preview")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Inline Video Player

struct InlineVideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loopObserver: NSObjectProtocol?

        func replaceObserver(for player: AVPlayer) {
            if let old = loopObserver {
                NotificationCenter.default.removeObserver(old)
            }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }

        deinit {
            if let obs = loopObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false

        let player = AVPlayer(url: url)
        playerView.player = player
        context.coordinator.replaceObserver(for: player)
        player.play()

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if let currentURL = (playerView.player?.currentItem?.asset as? AVURLAsset)?.url,
           currentURL != url {
            playerView.player?.pause()
            let player = AVPlayer(url: url)
            playerView.player = player
            context.coordinator.replaceObserver(for: player)
            player.play()
        }
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        if let obs = coordinator.loopObserver {
            NotificationCenter.default.removeObserver(obs)
            coordinator.loopObserver = nil
        }
        playerView.player?.pause()
        playerView.player = nil
    }
}
