import AppKit

/// A full-screen transparent overlay for drag-to-select region capture.
/// Shows crosshair cursor, selection rectangle with dimensions, and dim overlay.
final class RegionSelectionPanel: NSPanel {

    var onRegionSelected: ((CGRect, NSScreen) -> Void)?
    var onCancelled: (() -> Void)?

    private let selectionView: RegionSelectionView

    init(screen: NSScreen) {
        selectionView = RegionSelectionView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false

        selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
        selectionView.autoresizingMask = [.width, .height]
        selectionView.onRegionSelected = { [weak self] rect in
            guard let self else { return }
            // Convert from view coordinates to screen coordinates
            let screenRect = CGRect(
                x: self.frame.origin.x + rect.origin.x,
                y: self.frame.origin.y + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
            self.close()
            self.onRegionSelected?(screenRect, screen)
        }
        selectionView.onCancelled = { [weak self] in
            self?.close()
            self?.onCancelled?()
        }

        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showAndActivate() {
        makeKeyAndOrderFront(nil)
        selectionView.window?.makeFirstResponder(selectionView)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            onCancelled?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Selection View

private final class RegionSelectionView: NSView {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim overlay
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()

        guard let rect = currentRect, rect.width > 0, rect.height > 0 else { return }

        // Clear the selected region (punch through the dim)
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        // Selection border
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let borderPath = NSBezierPath(rect: rect)
        borderPath.lineWidth = 2
        borderPath.stroke()

        // Dimension label
        let width = Int(rect.width)
        let height = Int(rect.height)
        let text = "\(width) × \(height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()

        // Background pill for the label
        let pillPadding: CGFloat = 6
        let pillRect = NSRect(
            x: rect.midX - (textSize.width + pillPadding * 2) / 2,
            y: rect.minY - textSize.height - pillPadding * 2 - 6,
            width: textSize.width + pillPadding * 2,
            height: textSize.height + pillPadding
        )

        // Only draw label if it fits on screen
        if pillRect.minY > bounds.minY {
            NSColor.black.withAlphaComponent(0.7).setFill()
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            pillPath.fill()

            let textOrigin = NSPoint(
                x: pillRect.origin.x + pillPadding,
                y: pillRect.origin.y + pillPadding / 2
            )
            attrString.draw(at: textOrigin)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)

        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)

        currentRect = NSRect(x: x, y: y, width: w, height: h)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect else {
            onCancelled?()
            return
        }

        // Minimum 20×20 region
        if rect.width < 20 || rect.height < 20 {
            currentRect = nil
            needsDisplay = true
            onCancelled?()
            return
        }

        onRegionSelected?(rect)
    }
}
