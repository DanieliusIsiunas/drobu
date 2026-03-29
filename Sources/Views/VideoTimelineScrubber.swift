import AppKit
import SwiftUI

/// Horizontal timeline scrubber with draggable start/end handles for video trimming.
/// Time-based (seconds) rather than frame-based, otherwise mirrors TimelineScrubber.
struct VideoTimelineScrubber: NSViewRepresentable {
    let duration: Double       // total video duration in seconds
    @Binding var startTime: Double
    @Binding var endTime: Double
    let currentTime: Double    // playhead position (read-only)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> VideoScrubberNSView {
        let view = VideoScrubberNSView()
        view.coordinator = context.coordinator
        view.duration = duration
        view.startTime = startTime
        view.endTime = endTime
        view.currentTime = currentTime
        return view
    }

    func updateNSView(_ nsView: VideoScrubberNSView, context: Context) {
        nsView.duration = duration
        nsView.startTime = startTime
        nsView.endTime = endTime
        nsView.currentTime = currentTime
        nsView.needsDisplay = true
    }

    @MainActor
    final class Coordinator {
        var parent: VideoTimelineScrubber

        init(_ parent: VideoTimelineScrubber) {
            self.parent = parent
        }

        func updateStart(_ value: Double) {
            parent.startTime = value
        }

        func updateEnd(_ value: Double) {
            parent.endTime = value
        }
    }
}

// MARK: - Native NSView

final class VideoScrubberNSView: NSView {
    weak var coordinator: VideoTimelineScrubber.Coordinator?
    var duration: Double = 0
    var startTime: Double = 0
    var endTime: Double = 0
    var currentTime: Double = 0

    private let handleWidth: CGFloat = 14
    private let minimumSelection: Double = 0.5  // seconds
    private var dragTarget: DragTarget?

    private enum DragTarget { case start, end }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var usableWidth: CGFloat {
        bounds.width - handleWidth * 2
    }

    private func timeFromX(_ x: CGFloat) -> Double {
        guard usableWidth > 0, duration > 0 else { return 0 }
        let fraction = (x - handleWidth) / usableWidth
        return max(0, min(Double(fraction) * duration, duration))
    }

    private func xFromTime(_ time: Double) -> CGFloat {
        guard duration > 0 else { return handleWidth }
        return handleWidth + CGFloat(time / duration) * usableWidth
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let startCenter = xFromTime(startTime) - handleWidth / 2
        let endCenter = xFromTime(endTime) + handleWidth / 2

        dragTarget = abs(location.x - startCenter) <= abs(location.x - endCenter)
            ? .start : .end
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let time = timeFromX(location.x)

        switch dragTarget {
        case .start:
            let clamped = max(0, min(time, endTime - minimumSelection))
            startTime = clamped
            coordinator?.updateStart(clamped)
        case .end:
            let clamped = min(duration, max(time, startTime + minimumSelection))
            endTime = clamped
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
        guard duration > 0 else { return }

        let barHeight = bounds.height

        // Background track
        let trackRect = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.08).setFill()
        trackPath.fill()

        // Selected range highlight
        let startX = xFromTime(startTime)
        let endX = xFromTime(endTime)
        let rangeRect = NSRect(x: startX, y: 0, width: max(0, endX - startX), height: barHeight)
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: rangeRect).fill()

        // Playhead
        if currentTime >= startTime && currentTime <= endTime {
            let playX = xFromTime(currentTime)
            let playRect = NSRect(x: playX - 1, y: 0, width: 2, height: barHeight)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: playRect).fill()
        }

        // Start handle
        let startHandleX = xFromTime(startTime) - handleWidth
        let startHandleRect = NSRect(x: startHandleX, y: 0, width: handleWidth, height: barHeight)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: startHandleRect, xRadius: 3, yRadius: 3).fill()

        // End handle
        let endHandleX = xFromTime(endTime)
        let endHandleRect = NSRect(x: endHandleX, y: 0, width: handleWidth, height: barHeight)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: endHandleRect, xRadius: 3, yRadius: 3).fill()
    }
}

// MARK: - SwiftUI wrapper with duration label

struct VideoTimelineScrubberWithLabel: View {
    let duration: Double
    @Binding var startTime: Double
    @Binding var endTime: Double
    let currentTime: Double

    var body: some View {
        VStack(spacing: 4) {
            VideoTimelineScrubber(
                duration: duration,
                startTime: $startTime,
                endTime: $endTime,
                currentTime: currentTime
            )
            .frame(height: 28)

            let trimmed = endTime - startTime
            HStack {
                if trimmed < duration - 0.1 {
                    Text("\(formatDuration(trimmed)) of \(formatDuration(duration))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(formatDuration(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
