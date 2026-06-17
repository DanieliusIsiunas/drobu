import AppKit
import SwiftUI

/// Crop overlay with four draggable corner handles and a live pixel readout.
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
/// stay with the host editor's key view. Clicks away from the corner handles fall
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
        // Accessibility value updates live in the NSView's geometry didSet (guarded by
        // != oldValue) — updateNSView fires at playback rate (30Hz video, 10Hz GIF)
        // and an unconditional setAccessibilityValue here would churn VoiceOver.
        nsView.geometry = geometry
        nsView.isInteractionEnabled = isInteractionEnabled
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
            setAccessibilityValue(geometry.readoutText)
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

    private var dragCorner: CropGeometry.Corner?
    /// View-space offset from the grabbed corner's anchor to the mousedown point,
    /// so dragging tracks the cursor delta instead of teleporting the corner to it.
    private var grabOffset: CGSize = .zero
    /// Max corner grab radius; the effective slop shrinks on a tiny crop so adjacent
    /// zones never overlap (see `effectiveCornerSlop`).
    private let cornerSlop: CGFloat = 18
    /// Max L-bracket leg length, in points.
    private let handleLegMax: CGFloat = 18

    override var isFlipped: Bool { true }

    // Respond to first click without needing window activation
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Prevent window dragging when interacting with a crop corner handle
    override var mouseDownCanMoveWindow: Bool { false }

    /// The corner grab radius for the current crop, clamped so adjacent corners'
    /// square zones never overlap (half the smaller displayed side). On a normal
    /// crop this is just `cornerSlop`; it only shrinks on a very small crop.
    private func effectiveCornerSlop(forFitted fitted: NSRect) -> CGFloat {
        let rect = geometry.viewCropRect(fittedRect: fitted)
        return min(cornerSlop, min(rect.width, rect.height) / 2)
    }

    /// Only claim clicks near a crop corner; everything else falls through to the
    /// player below (keeps window-drag-by-background working mid-frame).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled, geometry.isCroppable else { return nil }
        let local = convert(point, from: superview)
        let fitted = geometry.fittedRect(in: bounds.size)
        let slop = effectiveCornerSlop(forFitted: fitted)
        guard geometry.nearestCorner(atViewPoint: local, fittedRect: fitted, slop: slop) != nil else {
            return nil
        }
        return self
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled, geometry.isCroppable else { return }
        let location = convert(event.locationInWindow, from: nil)
        let fitted = geometry.fittedRect(in: bounds.size)
        let slop = effectiveCornerSlop(forFitted: fitted)
        guard let corner = geometry.nearestCorner(atViewPoint: location, fittedRect: fitted, slop: slop) else {
            dragCorner = nil
            return
        }
        dragCorner = corner
        // Remember where inside the grab zone the corner was clicked, so the first
        // drag delta doesn't snap the corner to the cursor.
        let anchor = corner.point(in: geometry.viewCropRect(fittedRect: fitted))
        grabOffset = CGSize(width: anchor.x - location.x, height: anchor.y - location.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let corner = dragCorner else { return }
        let location = convert(event.locationInWindow, from: nil)
        let fitted = geometry.fittedRect(in: bounds.size)
        let tracked = CGPoint(x: location.x + grabOffset.width, y: location.y + grabOffset.height)
        let contentPoint = geometry.contentPoint(fromViewPoint: tracked, fittedRect: fitted)
        geometry.drag(corner: corner, toContentPoint: contentPoint)
        onGeometryChange?(geometry)
    }

    override func mouseUp(with event: NSEvent) {
        dragCorner = nil
    }

    // MARK: - Cursors

    override func resetCursorRects() {
        guard isInteractionEnabled, geometry.isCroppable else { return }
        let fitted = geometry.fittedRect(in: bounds.size)
        let rect = geometry.viewCropRect(fittedRect: fitted)

        // A square grab zone centered on each corner, sized to the same effective
        // slop the hit-test uses. macOS exposes no public diagonal-resize NSCursor —
        // crosshair is the honest "grab this point" cue.
        let slop = effectiveCornerSlop(forFitted: fitted)
        for corner in CropGeometry.Corner.allCases {
            let p = corner.point(in: rect)
            let zone = NSRect(x: p.x - slop, y: p.y - slop, width: slop * 2, height: slop * 2)
            addCursorRect(zone.intersection(bounds), cursor: .crosshair)
        }
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

        // Corner grip handles — the visible, draggable affordance.
        drawCornerHandles(in: cropViewRect)

        drawReadoutPill(anchoredIn: cropViewRect)
    }

    /// Four L-shaped corner brackets hugging the crop rect's corners. The
    /// actively-dragged corner draws in the accent color; the rest are white with
    /// a soft halo so they read on both light and dark content.
    private func drawCornerHandles(in rect: NSRect) {
        // Leg ~40% of the smaller displayed side, capped at handleLegMax. The 0.4
        // factor keeps the two legs that share an edge from ever crossing
        // (2 × 0.4 < 1), even on a tiny crop — so there is no fixed floor, which
        // would defeat that guarantee.
        let leg = min(handleLegMax, min(rect.width, rect.height) * 0.4)

        // Offset-free blur halo: reads on light AND dark content and is immune to
        // the flipped-coordinate shadow-offset direction trap.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        for corner in CropGeometry.Corner.allCases {
            let anchor = corner.point(in: rect)
            // Inward leg directions (view is flipped, so +y is downward).
            let dx: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? 1 : -1
            let dy: CGFloat = (corner == .topLeft || corner == .topRight) ? 1 : -1
            let color: NSColor = corner == dragCorner
                ? .controlAccentColor
                : NSColor.white.withAlphaComponent(0.95)
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: anchor.x + dx * leg, y: anchor.y))
            path.line(to: anchor)
            path.line(to: NSPoint(x: anchor.x, y: anchor.y + dy * leg))
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
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
