import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// AVPlayer-based video player that loops within a trim range.
/// Accepts first responder for keyboard handling (Cmd+Return to save, Escape to discard).
struct VideoTrimPlayerView: NSViewRepresentable {
    let url: URL
    let startTime: Double
    let endTime: Double
    @Binding var currentTime: Double
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VideoTrimNSView {
        let view = VideoTrimNSView()
        view.onSave = onSave
        view.onDiscard = onDiscard

        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let player = AVPlayer(url: url)
        playerView.player = player
        context.coordinator.player = player
        context.coordinator.playerView = playerView

        // Periodic time observer at 30Hz for smooth playhead.
        // The observer closure is @Sendable but fires on queue: .main; Coordinator
        // is @MainActor (so it's Sendable and legal to capture here), and the body
        // runs under MainActor.assumeIsolated since we know the callback is on main.
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        let coord = context.coordinator
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coord] time in
            MainActor.assumeIsolated {
                guard let coord else { return }
                let secs = time.seconds
                coord.currentTimeBinding?.wrappedValue = secs

                // Loop within range
                if secs >= coord.endTime {
                    player.seek(to: CMTime(seconds: coord.startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
        coord.timeObserver = observer
        coord.startTime = startTime
        coord.endTime = endTime
        coord.currentTimeBinding = $currentTime

        // Seek to start and play
        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()

        // Acquire focus
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: VideoTrimNSView, context: Context) {
        let coord = context.coordinator
        nsView.onSave = onSave
        nsView.onDiscard = onDiscard
        coord.currentTimeBinding = $currentTime

        let rangeChanged = coord.startTime != startTime || coord.endTime != endTime
        coord.startTime = startTime
        coord.endTime = endTime

        if rangeChanged, let player = coord.player {
            let current = player.currentTime().seconds
            if current < startTime || current > endTime {
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    static func dismantleNSView(_ nsView: VideoTrimNSView, coordinator: Coordinator) {
        if let player = coordinator.player, let observer = coordinator.timeObserver {
            player.removeTimeObserver(observer)
        }
        coordinator.player?.pause()
        coordinator.player = nil
        coordinator.timeObserver = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var player: AVPlayer?
        var playerView: AVPlayerView?
        var timeObserver: Any?
        var startTime: Double = 0
        var endTime: Double = 0
        var currentTimeBinding: Binding<Double>?
    }
}

// MARK: - Player container NSView (key handling inherited from EditorKeyNSView)

final class VideoTrimNSView: EditorKeyNSView {}
