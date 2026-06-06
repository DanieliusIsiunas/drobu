import AppKit
import SwiftUI

/// Crop overlay with four draggable edges and a live pixel readout.
///
/// Uses NSViewRepresentable with native mouse handling (like `TimelineScrubber`) to
/// avoid conflicts with the floating panel's `isMovableByWindowBackground` and
/// `nonActivatingPanel` style. The NSView is flipped so all drawing and hit-testing
/// share `CropGeometry`'s top-left-origin convention — `RegionSelectionView` is a
/// drawing-idiom precedent only (it is bottom-left; borrow visuals, not coordinates).
///
/// The overlay computes the displayed-frame rect itself (aspect-fit of the content
/// pixel size inside its own bounds), so it recomputes correctly on every layout
/// pass and panel resize. It never takes first-responder status — Esc/Cmd+Return
/// stay with the host editor's key view. Clicks away from the crop edges fall
/// through (`hitTest` returns nil), so window dragging on the player still works.
struct CropOverlayView: NSViewRepresentable {
    @Binding var geometry: CropGeometry
    var isInteractionEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CropOverlayNSView {
        let view = CropOverlayNSView()
        view.geometry = geometry
        view.isInteractionEnabled = isInteractionEnabled
        let coordinator = context.coordinator
        view.onGeometryChange = { newGeometry in
            coordinator.parent.geometry = newGeometry
        }

        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Crop area")
        view.setAccessibilityValue(geometry.readoutText)
        return view
    }

    func updateNSView(_ nsView: CropOverlayNSView, context: Context) {
        context.coordinator.parent = self
        nsView.geometry = geometry
        nsView.isInteractionEnabled = isInteractionEnabled
        nsView.setAccessibilityValue(geometry.readoutText)
    }

    @MainActor
    final class Coordinator {
        var parent: CropOverlayView

        init(_ parent: CropOverlayView) {
            self.parent = parent
        }
    }
}

// MARK: - Native overlay view

final class CropOverlayNSView: NSView {
    var geometry = CropGeometry(contentWidth: 0, contentHeight: 0) {
        didSet {
            guard geometry != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onGeometryChange: ((CropGeometry) -> Void)?
    var isInteractionEnabled = true {
        didSet {
            guard isInteractionEnabled != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private var dragEdge: CropGeometry.Edge?
    private let hitSlop: CGFloat = 10

    override var isFlipped: Bool { true }

    // Respond to first click without needing window activation
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Prevent window dragging when interacting with a crop edge
    override var mouseDownCanMoveWindow: Bool { false }

    /// Only claim clicks near a crop edge; everything else falls through to the
    /// player below (keeps window-drag-by-background working mid-frame).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled, geometry.isCroppable else { return nil }
        let local = convert(point, from: superview)
        let fitted = geometry.fittedRect(in: bounds.size)
        guard geometry.nearestEdge(atViewPoint: local, fittedRect: fitted, slop: hitSlop) != nil else {
            return nil
        }
        return self
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled, geometry.isCroppable else { return }
        let location = convert(event.locationInWindow, from: nil)
        let fitted = geometry.fittedRect(in: bounds.size)
        dragEdge = geometry.nearestEdge(atViewPoint: location, fittedRect: fitted, slop: hitSlop)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let edge = dragEdge else { return }
        let location = convert(event.locationInWindow, from: nil)
        let fitted = geometry.fittedRect(in: bounds.size)
        let contentPoint = geometry.contentPoint(fromViewPoint: location, fittedRect: fitted)
        geometry.drag(edge: edge, toContentPoint: contentPoint)
        onGeometryChange?(geometry)
    }

    override func mouseUp(with event: NSEvent) {
        dragEdge = nil
    }

    // MARK: - Cursors

    override func resetCursorRects() {
        guard isInteractionEnabled, geometry.isCroppable else { return }
        let fitted = geometry.fittedRect(in: bounds.size)
        let rect = geometry.viewCropRect(fittedRect: fitted)

        let leftBand = NSRect(x: rect.minX - hitSlop, y: rect.minY, width: hitSlop * 2, height: rect.height)
        let rightBand = NSRect(x: rect.maxX - hitSlop, y: rect.minY, width: hitSlop * 2, height: rect.height)
        let topBand = NSRect(x: rect.minX, y: rect.minY - hitSlop, width: rect.width, height: hitSlop * 2)
        let bottomBand = NSRect(x: rect.minX, y: rect.maxY - hitSlop, width: rect.width, height: hitSlop * 2)

        addCursorRect(leftBand.intersection(bounds), cursor: .resizeLeftRight)
        addCursorRect(rightBand.intersection(bounds), cursor: .resizeLeftRight)
        addCursorRect(topBand.intersection(bounds), cursor: .resizeUpDown)
        addCursorRect(bottomBand.intersection(bounds), cursor: .resizeUpDown)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard geometry.contentWidth > 0, geometry.contentHeight > 0 else { return }
        let fitted = geometry.fittedRect(in: bounds.size)
        guard fitted.width > 0, fitted.height > 0 else { return }

        guard geometry.isCroppable else {
            // Too-small state: a single non-interactive border plus the readout.
            strokeBorder(around: fitted, color: NSColor.white.withAlphaComponent(0.4))
            drawReadoutPill(anchoredIn: fitted)
            return
        }

        let cropViewRect = geometry.viewCropRect(fittedRect: fitted)

        // Dim the content outside the crop rect (punch the crop through the dim).
        NSColor.black.withAlphaComponent(0.45).setFill()
        fitted.fill()
        NSColor.clear.setFill()
        cropViewRect.fill(using: .copy)

        // Crop border
        strokeBorder(around: cropViewRect, color: NSColor.white.withAlphaComponent(0.8))

        // Active-edge emphasis while dragging
        if let edge = dragEdge {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 3
            switch edge {
            case .left:
                path.move(to: NSPoint(x: cropViewRect.minX, y: cropViewRect.minY))
                path.line(to: NSPoint(x: cropViewRect.minX, y: cropViewRect.maxY))
            case .right:
                path.move(to: NSPoint(x: cropViewRect.maxX, y: cropViewRect.minY))
                path.line(to: NSPoint(x: cropViewRect.maxX, y: cropViewRect.maxY))
            case .top:
                path.move(to: NSPoint(x: cropViewRect.minX, y: cropViewRect.minY))
                path.line(to: NSPoint(x: cropViewRect.maxX, y: cropViewRect.minY))
            case .bottom:
                path.move(to: NSPoint(x: cropViewRect.minX, y: cropViewRect.maxY))
                path.line(to: NSPoint(x: cropViewRect.maxX, y: cropViewRect.maxY))
            }
            path.stroke()
        }

        drawReadoutPill(anchoredIn: cropViewRect)
    }

    private func strokeBorder(around rect: NSRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    /// Dimension pill anchored inside-top-center of the given rect, 8pt offset.
    /// Hidden when the rect is too short to host it without crowding.
    private func drawReadoutPill(anchoredIn rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let attrString = NSAttributedString(string: geometry.readoutText, attributes: attributes)
        let textSize = attrString.size()

        let pillPadding: CGFloat = 6
        let pillHeight = textSize.height + pillPadding
        guard rect.height >= pillHeight * 2 else { return }

        let pillRect = NSRect(
            x: rect.midX - (textSize.width + pillPadding * 2) / 2,
            y: rect.minY + 8,
            width: textSize.width + pillPadding * 2,
            height: pillHeight
        )

        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()

        attrString.draw(at: NSPoint(
            x: pillRect.origin.x + pillPadding,
            y: pillRect.origin.y + pillPadding / 2
        ))
    }
}
