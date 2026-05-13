import AppKit
import SwiftUI

/// Small floating panel shown in place of the clipboard panel once the
/// 14-day trial has expired and no license key is active. Hosts the
/// `ActivationView` (Buy + paste-key form).
///
/// Deliberately simpler than `FloatingPanel`: no keystroke buffering, no
/// shift-tap, no paste mechanics — this surface only collects a license
/// key string and routes Buy clicks to Stripe. Once activation succeeds
/// the panel dismisses itself; the next hotkey press opens the real
/// clipboard panel.
final class ActivationPanel: NSPanel {
    init(licenseManager: LicenseManager) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear

        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        title = "Activate Drobu"

        contentView = NSHostingView(rootView:
            ActivationView(licenseManager: licenseManager, onActivated: { [weak self] in
                self?.close()
            })
            .ignoresSafeArea()
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showCentered() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2 + 60
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
    }
}
