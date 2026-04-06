import AppKit
import SwiftUI

/// Horizontal timeline scrubber with draggable start/end handles for GIF trimming.
/// Uses NSViewRepresentable with native mouse handling to avoid conflicts with
/// the floating panel's `isMovableByWindowBackground` and `nonActivatingPanel` style.
struct TimelineScrubber: NSViewRepresentable {
    let frameCount: Int
    @Binding var startFrame: Int
    @Binding var endFrame: Int
    let currentFrame: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ScrubberNSView {
        let view = ScrubberNSView()
        view.coordinator = context.coordinator
        view.frameCount = frameCount
        view.startFrame = startFrame
        view.endFrame = endFrame
        view.currentFrame = currentFrame
        view.setAccessibilityRole(.slider)
        view.setAccessibilityLabel("GIF timeline, frames \(startFrame) to \(endFrame) of \(frameCount)")
        return view
    }

    func updateNSView(_ nsView: ScrubberNSView, context: Context) {
        nsView.frameCount = frameCount
        nsView.startFrame = startFrame
        nsView.endFrame = endFrame
        nsView.currentFrame = currentFrame
        nsView.needsDisplay = true
        nsView.setAccessibilityLabel("GIF timeline, frames \(startFrame) to \(endFrame) of \(frameCount)")
    }

    @MainActor
    final class Coordinator {
        var parent: TimelineScrubber

        init(_ parent: TimelineScrubber) {
            self.parent = parent
        }

        func updateStart(_ value: Int) {
            parent.startFrame = value
        }

        func updateEnd(_ value: Int) {
            parent.endFrame = value
        }
    }
}

// MARK: - Native NSView for scrubber

final class ScrubberNSView: NSView {
    weak var coordinator: TimelineScrubber.Coordinator?
    var frameCount: Int = 0
    var startFrame: Int = 0
    var endFrame: Int = 0
    var currentFrame: Int = 0

    private let handleWidth: CGFloat = 14
    private let minimumFrameSelection = 2
    private var dragTarget: DragTarget?

    private enum DragTarget {
        case start, end
    }

    // Respond to first click without needing window activation
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Prevent window dragging when interacting with the scrubber
    override var mouseDownCanMoveWindow: Bool { false }

    private var usableWidth: CGFloat {
        bounds.width - handleWidth * 2
    }

    private var frameWidth: CGFloat {
        frameCount > 1 ? usableWidth / CGFloat(frameCount - 1) : usableWidth
    }

    private func frameFromX(_ x: CGFloat) -> Int {
        guard frameWidth > 0 else { return 0 }
        return Int(round((x - handleWidth) / frameWidth))
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let startCenter = handleWidth / 2 + CGFloat(startFrame) * frameWidth
        let endCenter = CGFloat(endFrame) * frameWidth + handleWidth + handleWidth / 2

        // Pick the closest handle
        dragTarget = abs(location.x - startCenter) <= abs(location.x - endCenter)
            ? .start : .end
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let newFrame = frameFromX(location.x)

        switch dragTarget {
        case .start:
            let clamped = max(0, min(newFrame, endFrame - minimumFrameSelection))
            startFrame = clamped
            coordinator?.updateStart(clamped)
        case .end:
            let clamped = min(frameCount - 1, max(newFrame, startFrame + minimumFrameSelection))
            endFrame = clamped
            coordinator?.updateEnd(clamped)
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard frameCount > 0 else { return }

        let barHeight = bounds.height
        let fw = frameWidth

        // Background track
        let trackRect = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.08).setFill()
        trackPath.fill()

        // Selected range highlight
        let startX = handleWidth + CGFloat(startFrame) * fw
        let endX = handleWidth + CGFloat(endFrame) * fw
        let rangeRect = NSRect(x: startX, y: 0, width: max(0, endX - startX), height: barHeight)
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: rangeRect).fill()

        // Playhead
        if currentFrame >= startFrame && currentFrame <= endFrame {
            let playX = handleWidth + CGFloat(currentFrame) * fw
            let playRect = NSRect(x: playX - 1, y: 0, width: 2, height: barHeight)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: playRect).fill()
        }

        // Start handle
        let startHandleRect = NSRect(x: CGFloat(startFrame) * fw, y: 0, width: handleWidth, height: barHeight)
        let startPath = NSBezierPath(roundedRect: startHandleRect, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.setFill()
        startPath.fill()

        // End handle
        let endHandleRect = NSRect(x: CGFloat(endFrame) * fw + handleWidth, y: 0, width: handleWidth, height: barHeight)
        let endPath = NSBezierPath(roundedRect: endHandleRect, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.setFill()
        endPath.fill()
    }
}

// MARK: - SwiftUI wrapper that adds the frame counter label

struct TimelineScrubberWithLabel: View {
    let frameCount: Int
    @Binding var startFrame: Int
    @Binding var endFrame: Int
    let currentFrame: Int

    var body: some View {
        VStack(spacing: 4) {
            TimelineScrubber(
                frameCount: frameCount,
                startFrame: $startFrame,
                endFrame: $endFrame,
                currentFrame: currentFrame
            )
            .frame(height: 28)

            Text("Frames \(startFrame + 1)\u{2013}\(endFrame + 1) of \(frameCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
