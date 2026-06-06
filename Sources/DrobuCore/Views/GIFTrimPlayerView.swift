import AppKit
import SwiftUI

/// Frame-by-frame GIF player that loops within a given range.
/// Accepts first responder for keyboard handling (Cmd+Return to save, Escape to discard).
struct GIFTrimPlayerView: NSViewRepresentable {
    let frames: [GIFFrame]
    let startFrame: Int
    let endFrame: Int
    @Binding var currentFrame: Int
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> GIFPlayerNSView {
        let view = GIFPlayerNSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onSave = onSave
        view.onDiscard = onDiscard

        context.coordinator.hostView = view
        context.coordinator.startPlayback()

        // Acquire focus after layout (same pattern as EditableTextView)
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: GIFPlayerNSView, context: Context) {
        let coord = context.coordinator
        let rangeChanged = coord.startFrame != startFrame || coord.endFrame != endFrame
        coord.parent = self
        coord.startFrame = startFrame
        coord.endFrame = endFrame
        nsView.onSave = onSave
        nsView.onDiscard = onDiscard

        if rangeChanged {
            if coord.displayedFrame < startFrame || coord.displayedFrame > endFrame {
                coord.displayedFrame = startFrame
                coord.displayFrame(startFrame)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var parent: GIFTrimPlayerView
        var hostView: NSView?
        var startFrame: Int
        var endFrame: Int
        var displayedFrame: Int
        nonisolated(unsafe) private var timer: DispatchWorkItem?

        init(_ parent: GIFTrimPlayerView) {
            self.parent = parent
            self.startFrame = parent.startFrame
            self.endFrame = parent.endFrame
            self.displayedFrame = parent.startFrame
        }

        func startPlayback() {
            displayedFrame = startFrame
            scheduleNextFrame()
        }

        func displayFrame(_ index: Int) {
            guard index < parent.frames.count else { return }
            let frame = parent.frames[index]
            hostView?.layer?.contents = frame.image
            parent.currentFrame = index
        }

        private func scheduleNextFrame() {
            timer?.cancel()

            let frameIndex = displayedFrame
            guard frameIndex < parent.frames.count else { return }

            displayFrame(frameIndex)

            let delay = parent.frames[frameIndex].delay
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                var next = self.displayedFrame + 1
                if next > self.endFrame {
                    next = self.startFrame
                }
                self.displayedFrame = next
                self.scheduleNextFrame()
            }
            timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        deinit {
            timer?.cancel()
        }
    }
}

// MARK: - Player NSView (key handling inherited from EditorKeyNSView)

final class GIFPlayerNSView: EditorKeyNSView {}
