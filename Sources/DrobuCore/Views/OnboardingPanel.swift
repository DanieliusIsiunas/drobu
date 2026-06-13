import AppKit
import CoreGraphics
import SwiftUI

/// Performs an `OnboardingAction` against the real platform APIs. System
/// boundary (deep-links, CG/AX requests, daemon remediation, relaunch) — kept
/// thin and excluded from unit tests; the decision logic that produces these
/// actions lives in `OnboardingViewModel` (tested).
@MainActor
struct OnboardingActuator {
    func perform(_ action: OnboardingAction) {
        switch action {
        case .openAccessibilitySettings:
            openSystemPrivacyPane("Privacy_Accessibility")
        case .openScreenRecordingSettings:
            // Add Drobu to the Screen Recording list first (so the toggle
            // exists in Settings), then deep-link — mirrors the capture services.
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            openSystemPrivacyPane("Privacy_ScreenCapture")
        case .openPasteboardSettings:
            openSystemPrivacyPane("Privacy_Pasteboard")
        case .enableClosedLidHelper:
            // State-correct: .notFound registers first, only .requiresApproval deep-links.
            _ = DaemonRegistrar().remediate()
        case .toggleLaunchAtLogin(let enable):
            let agent = MainAppLaunchAgentControl()
            do {
                if enable { try agent.register() } else { try agent.unregister() }
            } catch {
                Log.error("OnboardingActuator: launch-at-login toggle failed: \(error)")
            }
        case .restart:
            relaunch()
        }
    }

    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
            // Only quit the current instance once the new one is actually
            // launching. If the relaunch fails (bundle moved, LaunchServices
            // error), terminating anyway would leave NO Drobu running — keep
            // this instance alive and log instead.
            let launched = app != nil && error == nil
            let errorDesc = error?.localizedDescription
            DispatchQueue.main.async {
                if launched {
                    NSApp.terminate(nil)
                } else {
                    Log.error("OnboardingActuator: relaunch failed, keeping current instance running: \(errorDesc ?? "unknown error")")
                }
            }
        }
    }
}

/// First-launch onboarding window. Floating `NSPanel` on the `ActivationPanel`
/// model (AppDelegate-owned, `canBecomeKey`, app stays `.accessory`), recreated
/// each show. While visible it re-polls permissions on app activation and a
/// `.common`-mode timer so rows flip live as the user grants each one. Any
/// dismissal marks onboarding complete so it never nags again.
final class OnboardingPanel: NSPanel {
    private let model: OnboardingViewModel
    private let gate: OnboardingGate
    private let actuator = OnboardingActuator()
    private var refreshTimer: Timer?
    private var activeObserver: Any?
    private var onClose: (() -> Void)?

    init(permissions: PermissionsService, gate: OnboardingGate, onClose: @escaping () -> Void) {
        self.model = OnboardingViewModel(permissions: permissions)
        self.gate = gate
        self.onClose = onClose
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
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
        title = "Set Up Drobu"

        contentView = NSHostingView(rootView:
            OnboardingView(
                model: model,
                onAction: { [weak self] action in
                    self?.actuator.perform(action)
                    // Re-poll right away; the didBecomeActive re-check covers the
                    // return-from-System-Settings case for the deep-link actions.
                    self?.model.refresh()
                },
                onFinish: { [weak self] in self?.close() }
            )
            .ignoresSafeArea()
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showCentered() {
        startLiveRefresh()
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2 + 40))
        }
        makeKeyAndOrderFront(nil)
    }

    // Any dismissal — "Start using Drobu", "Skip for now", or the close button —
    // marks onboarding complete so it never auto-shows again (no nagging).
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
        ) { [weak self] _ in MainActor.assumeIsolated { self?.model.refresh() } }
        // Manual .common-mode timer so the poll keeps firing even if a menu/sheet
        // is up (scheduledTimer registers in .default only).
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
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
