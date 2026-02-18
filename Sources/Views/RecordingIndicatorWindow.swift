import AppKit

/// A small floating HUD shown during screen recording.
/// Displays a pulsing red dot, elapsed time, and stop hint.
/// Positioned outside the capture region so it's not included in the GIF.
final class RecordingIndicatorWindow: NSWindow {
    private let timerLabel = NSTextField(labelWithString: "0:00")
    private let dotView = NSView()
    private var updateTimer: Timer?
    private var startTime: Date?
    private var pulseLayer: CALayer?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false  // Required for ARC — prevents double-free on close()
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupContent()
    }

    private func setupContent() {
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        // Red recording dot
        dotView.frame = NSRect(x: 10, y: 9, width: 12, height: 12)
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        dotView.layer?.cornerRadius = 6
        container.addSubview(dotView)

        // Timer label
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timerLabel.textColor = .labelColor
        timerLabel.frame = NSRect(x: 28, y: 5, width: 40, height: 20)
        timerLabel.sizeToFit()
        timerLabel.frame.origin = NSPoint(x: 28, y: (30 - timerLabel.frame.height) / 2)
        container.addSubview(timerLabel)

        // Stop hint
        let hintLabel = NSTextField(labelWithString: "Press hotkey to stop")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.sizeToFit()
        hintLabel.frame.origin = NSPoint(x: 72, y: (30 - hintLabel.frame.height) / 2)
        container.addSubview(hintLabel)

        contentView = container
    }

    /// Show the indicator positioned outside the given capture region.
    func show(relativeTo captureRect: CGRect, on screen: NSScreen) {
        startTime = Date()
        timerLabel.stringValue = "0:00"

        // Position above the region, or below if too close to top of screen
        let screenFrame = screen.frame
        var origin: NSPoint
        if captureRect.minY > screenFrame.minY + 40 {
            // Above the capture region (AppKit coords: minY is bottom)
            origin = NSPoint(
                x: captureRect.midX - frame.width / 2,
                y: captureRect.minY - frame.height - 8
            )
        } else {
            // Below the capture region
            origin = NSPoint(
                x: captureRect.midX - frame.width / 2,
                y: captureRect.maxY + 8
            )
        }

        // Clamp to screen bounds
        origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - frame.width))
        origin.y = max(screenFrame.minY, min(origin.y, screenFrame.maxY - frame.height))

        setFrameOrigin(origin)
        orderFront(nil)

        // Start pulse animation on the red dot
        startPulseAnimation()

        // Update timer every 0.1s
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateElapsedTime()
            }
        }
    }

    func dismiss() {
        updateTimer?.invalidate()
        updateTimer = nil
        dotView.layer?.removeAllAnimations()
        close()
    }

    private func updateElapsedTime() {
        guard let start = startTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Int(elapsed) % 60
        let minutes = Int(elapsed) / 60
        timerLabel.stringValue = String(format: "%d:%02d", minutes, seconds)
    }

    private func startPulseAnimation() {
        guard let layer = dotView.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "pulse")
    }
}
