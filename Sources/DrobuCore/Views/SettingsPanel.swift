import AppKit
import SwiftUI

/// The unified Settings + first-run setup window. An AppDelegate-owned floating
/// `NSPanel` modeled on `OnboardingPanel` (`canBecomeKey`, app stays `.accessory`,
/// recreated each show — replaces both the old onboarding panel and the SwiftUI
/// `Settings` scene). Hosts `SettingsView` (sidebar + detail). First run opens to
/// the "Set Up" section with the onboarding welcome + CTA; afterwards it opens to
/// "Shortcuts" with Set Up as a plain, revisitable section.
final class SettingsPanel: NSWindow {
    private let nav: SettingsNavigationModel
    private let onboardingModel: OnboardingViewModel
    private let gate: OnboardingGate
    private let actuator = OnboardingActuator()
    private let firstRun: Bool
    private var refreshTimer: Timer?
    private var activeObserver: Any?
    private var onClose: (() -> Void)?

    init(permissions: PermissionsService, gate: OnboardingGate, firstRun: Bool,
         onRemoveClosedLidHelper: @escaping @MainActor () async -> Bool,
         onClose: @escaping () -> Void) {
        self.nav = SettingsNavigationModel(firstRun: firstRun)
        self.onboardingModel = OnboardingViewModel(permissions: permissions)
        self.gate = gate
        self.firstRun = firstRun
        self.onClose = onClose
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            // A standard titled WINDOW (not a floating NSPanel) so it shows the
            // native red/amber/green traffic-light trio. Deliberately NOT
            // .resizable: a fixed-size settings pane keeps the green button the
            // standard (disabled) zoom — adding .resizable turns it into the
            // macOS 15 "+ / Move & Resize" tiling button, which is wrong here.
            // fullSizeContentView + transparent titlebar keep the sidebar running
            // to the top edge; SettingsView reserves room for the controls via
            // its top inset.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        isReleasedWhenClosed = false
        title = "Drobu Settings"   // hidden visually; read by VoiceOver

        contentView = NSHostingView(rootView:
            SettingsView(
                nav: nav,
                onboardingModel: onboardingModel,
                firstRun: firstRun,
                windowProvider: { [weak self] in self },
                onPermissionAction: { [weak self] action in
                    guard let self else { return }
                    // Mark first-run onboarding complete only when a restart
                    // actually finishes required setup (mirrors OnboardingPanel).
                    if onboardingCompletesGate(on: action, completion: self.onboardingModel.completion) {
                        self.gate.markCompleted()
                    }
                    self.actuator.perform(action)
                    // Re-poll right away; the didBecomeActive re-check covers the
                    // return-from-System-Settings case for deep-link actions.
                    self.onboardingModel.refresh()
                },
                onRemoveClosedLidHelper: onRemoveClosedLidHelper,
                onFinish: { [weak self] in self?.close() }
            )
            .ignoresSafeArea()
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Show the window centered on the active screen and bring the (.accessory)
    /// app forward. Idempotent — safe to call to re-front an already-open window.
    func show() {
        startLiveRefresh()
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        if let screen, !isVisible {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2 + 40))
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Any dismissal marks onboarding complete (idempotent for ongoing opens) so
    /// first run never auto-nags again — mirrors OnboardingPanel.close().
    override func close() {
        stopLiveRefresh()
        gate.markCompleted()
        super.close()
        onClose?()
        onClose = nil
    }

    private func startLiveRefresh() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onboardingModel.refresh() } }
        // Manual .common-mode timer so the poll keeps firing even if a menu/sheet
        // is up (scheduledTimer registers in .default only).
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboardingModel.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
            activeObserver = nil
        }
    }
}
