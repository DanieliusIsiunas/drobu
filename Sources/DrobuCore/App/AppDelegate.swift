import AppKit
import ApplicationServices
import HotKey
import Sparkle

/// Ferries Sparkle's non-Sendable install block across the `nonisolated` →
/// main-actor hop in `updater(_:willInstallUpdateOnQuit:…)`. Safe as
/// `@unchecked Sendable` because the block is received, stored, and invoked
/// only on the main thread (Sparkle's installer driver dispatches to main).
private struct InstallBlockBox: @unchecked Sendable {
    let run: () -> Void
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private(set) var database: AppDatabase?
    private(set) var monitor: ClipboardMonitor?
    private var panel: FloatingPanel?
    private var hotKey: HotKey?
    private var cleanupTimer: Timer?
    private var hotkeyObserver: Any?
    private var captureHotKey: HotKey?
    private var captureHotkeyObserver: Any?
    private var captureService: ScreenCaptureService?
    private var videoCaptureHotKey: HotKey?
    private var videoCaptureHotkeyObserver: Any?
    private var videoCaptureService: VideoCaptureService?
    private var stopCaptureHotKey: HotKey?
    private var escStopHotKey: HotKey?
    private let caffeinateService = CaffeinateService()
    private let closedLidService = ClosedLidService()
    private var statusItem: NSStatusItem?
    private var badgeDotView: NSView?
    /// Top-right blue down-arrow glyph shown when a Sparkle update is waiting.
    /// Independent of badgeDotView (bottom-right sleep dot) so both can coexist.
    private var updateArrowView: NSView?
    /// Non-nil when a gentle (background) update is downloaded and waiting; drives
    /// the status-menu items and the icon arrow. Cleared when the user engages.
    private var pendingUpdateVersion: String?
    /// Set on the automatic-download path (willInstallUpdateOnQuit): invoking it
    /// installs the already-staged update and relaunches with no UI — what powers
    /// an instant "Restart to Update". Nil on the alert paths (fall back to
    /// resuming via the updater).
    private var immediateInstallBlock: (() -> Void)?
    /// The injected "update available" + "Restart to Update" items, tracked so
    /// they can be rebuilt independently of the sleep status items.
    private var updateMenuItems: [NSMenuItem] = []
    private var sleepStatusItems: [NSMenuItem] = []
    private var keepAwakeStatusItem: NSMenuItem?
    private var closedLidStatusItem: NSMenuItem?
    private var sleepStatusTimer: Timer?
    private var isMenuOpen = false
    private var signalSources: [DispatchSourceSignal] = []
    private var updaterController: SPUStandardUpdaterController?
    public private(set) var licenseManager: LicenseManager?
    private var licenseRefreshTimer: Timer?
    private var activationPanel: ActivationPanel?
    /// Single instance whose launch baseline backs the restart-pending status —
    /// created early in launch so it captures permission state before the user
    /// can change anything.
    private var permissionsService: PermissionsService?
    private var settingsPanel: SettingsPanel?
    /// Single first-run gate instance — it's a thin UserDefaults wrapper, but one
    /// owner avoids the auto-show check and the panel's mark-complete reading or
    /// writing through different objects.
    private let onboardingGate = OnboardingGate()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize database
        do {
            database = try AppDatabase()
        } catch {
            Log.error("AppDelegate: failed to initialize database: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }
        Log.info("AppDelegate: launch — pid \(ProcessInfo.processInfo.processIdentifier)")

        // License + trial state. Shared with SettingsView (which cannot
        // reach this delegate because Settings runs under .regular
        // activation policy). The static initializer fatalErrors if the
        // public key is missing — a build defect we want surfaced loudly.
        let mgr = LicenseManager.shared
        mgr.recordFirstLaunchIfNeeded()
        licenseManager = mgr

        // Snapshot the permission baseline as early as possible so the
        // restart-pending rule is accurate (a permission granted later this
        // session reads as pending-restart, not a false "ready").
        permissionsService = PermissionsService()
        // Hourly refresh so a session left running across the trial
        // boundary transitions to .trialExpired without user input; it also
        // re-validates the device-activation cap when the cached verdict is
        // stale (no-op otherwise; fails open on a backend outage).
        licenseRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                LicenseManager.shared.refresh()
                Task { await LicenseManager.shared.revalidateIfNeeded() }
            }
        }
        // Kick one re-validation at launch: registers this Mac for a user
        // grandfathered from a pre-cap build (R7), and promptly surfaces an
        // over-cap/revoked verdict. Fails open if offline.
        Task { await mgr.revalidateIfNeeded() }

        guard let db = database else { return }

        // Start clipboard monitoring
        monitor = ClipboardMonitor(database: db)
        monitor?.onAccessDenied = { [weak self] in
            self?.checkPasteboardPrivacy()
        }
        monitor?.start()

        // Register global hotkey from saved preference (or default Cmd+Shift+V)
        registerHotkey(HotkeyDefaults.load())

        // Re-register when user changes hotkey in preferences
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerHotkey(HotkeyDefaults.load())
            }
        }

        // Screen capture service + hotkey
        let service = ScreenCaptureService()
        service.onCaptureComplete = { [weak self] gifData in
            self?.handleCaptureComplete(gifData)
        }
        service.onCaptureError = { message in
            let alert = NSAlert()
            alert.messageText = "Screen Capture"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        service.onStateChange = { [weak self] _ in
            self?.refreshEscStopHotkey()
        }
        captureService = service
        registerCaptureHotkey(CaptureHotkeyDefaults.load())

        captureHotkeyObserver = NotificationCenter.default.addObserver(
            forName: .captureHotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerCaptureHotkey(CaptureHotkeyDefaults.load())
            }
        }

        // Video capture service + hotkey
        let videoService = VideoCaptureService()
        videoService.onCaptureComplete = { [weak self] videoURL, thumbnail, duration in
            self?.handleVideoCaptureComplete(videoURL: videoURL, thumbnail: thumbnail, duration: duration)
        }
        videoService.onCaptureError = { message in
            let alert = NSAlert()
            alert.messageText = "Video Capture"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        videoService.onStateChange = { [weak self] _ in
            self?.refreshEscStopHotkey()
        }
        videoCaptureService = videoService
        registerVideoCaptureHotkey(VideoCaptureHotkeyDefaults.load())

        videoCaptureHotkeyObserver = NotificationCenter.default.addObserver(
            forName: .videoCaptureHotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerVideoCaptureHotkey(VideoCaptureHotkeyDefaults.load())
            }
        }

        // Cmd+Esc to stop any active recording (GIF or video)
        stopCaptureHotKey = HotKey(keyCombo: KeyCombo(key: .escape, modifiers: .command))
        stopCaptureHotKey?.keyDownHandler = { [weak self] in
            self?.stopActiveRecording()
        }

        // Start Sparkle auto-update checks. We are BOTH delegates so updates are
        // surfaced gently (status menu + icon arrow) instead of a modal, on both
        // Sparkle paths: the updater delegate catches the common silent
        // auto-download (install-on-quit), and the user-driver delegate catches
        // the alert paths (impatient/critical/authorization). See the conformances
        // below.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        Log.info("AppDelegate: Sparkle updater started")

        // Set up menu bar status item with custom icon
        setupStatusItem()

        // Badge + status menu items: update when either sleep service changes state
        caffeinateService.onStateChange = { [weak self] _ in
            self?.refreshStatusIcon()
            self?.refreshSleepStatusItems()
        }
        closedLidService.onStateChange = { [weak self] _ in
            self?.refreshStatusIcon()
            self?.refreshSleepStatusItems()
        }

        // First launch: welcome the user and let them set up permissions up
        // front (replaces the old every-launch Accessibility modal — the Set Up
        // section owns first-run, and later lapses degrade gracefully in-context).
        showSettingsIfFirstRun()

        // Open the unified Settings panel from the `/settings` slash command
        // (the status-menu item calls showSettings() directly).
        _ = NotificationCenter.default.addObserver(
            forName: .openSettingsFromMenu, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }

        // Run cleanup on launch + schedule hourly
        runCleanup()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Defer cleanup while panel is visible
                guard self?.panel?.isVisible != true else { return }
                self?.runCleanup()
            }
        }

        // Launch-time rehydration (R14): adopt a live daemon session without a
        // new auth prompt or a second enable. A true orphan is reversed by the
        // daemon's own boot reconciliation, so there is nothing to adopt here.
        Task { await closedLidService.rehydrate() }

        // Closed Lid daemon surfaces (the Settings scene's `.alert` doesn't
        // fire, so these route through AppDelegate NSAlerts).
        _ = NotificationCenter.default.addObserver(
            forName: .daemonNotApproved, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showDaemonApprovalAlert() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .closedLidActivationFailed, object: nil, queue: .main
        ) { [weak self] note in
            // Extract the Sendable String before hopping isolation — the
            // Notification itself is non-Sendable and must not cross.
            let message = (note.userInfo?["message"] as? String) ?? "Closed Lid couldn't be activated."
            MainActor.assumeIsolated { self?.showClosedLidFailureAlert(message) }
        }

        // Re-validate the device-activation cap when the app regains focus —
        // the proven re-poll-on-didBecomeActive pattern. Surfaces a seat freed
        // (or refunded) elsewhere within one activation; no-op when the cached
        // verdict is fresh; fails open offline.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Task { await LicenseManager.shared.revalidateIfNeeded() }
                return
            }
        }

        // Signal handlers for SIGTERM/SIGHUP: best-effort cleanup of Closed Lid mode
        installSignalHandlers()
    }

    private func togglePanel() {
        // Panel may toggle while idle or while a recording is running (so
        // Drobu can record its own UI); blocked during region selection and
        // encoding/finalizing. Toggling never touches the capture services.
        guard CaptureUIPolicy.panelToggleAllowed(
            gif: captureService?.state ?? .idle,
            video: videoCaptureService?.state ?? .idle
        ) else { return }

        if let panel = panel, panel.isVisible {
            panel.close()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let database else { return }

        // Hard gate: when the license blocks use (trial expired, device cap
        // full, or revoked), route to the activation panel instead of the
        // clipboard panel. The clipboard monitor keeps running in the
        // background so the user's captured data is intact when they resolve it.
        if let mgr = licenseManager, mgr.status.blocksUsage {
            showActivationPanel(licenseManager: mgr)
            return
        }

        panel?.close()
        let sleepCommand = SleepCommand(caffeinateService: caffeinateService, closedLidService: closedLidService)
        let settingsCommand = SettingsCommand()
        panel = FloatingPanel {
            PanelView(
                database: database,
                commands: [sleepCommand, settingsCommand]
            )
        }
        panel?.showCentered()
        Log.info("AppDelegate: panel shown")
    }

    private func showActivationPanel(licenseManager: LicenseManager) {
        activationPanel?.close()
        activationPanel = ActivationPanel(licenseManager: licenseManager)
        activationPanel?.showCentered()
    }

    private func runCleanup() {
        let retentionDays = RetentionDefaults.loadRetentionDays()
        let maxCount = RetentionDefaults.loadMaxItemCount()

        Task.detached { [database] in
            guard let database else { return }
            do {
                try await database.pool.write { db in
                    try ClipboardRecord.cleanup(retentionDays: retentionDays, maxCount: maxCount, in: db)
                }

                // Cleanup file entries where all referenced files have been deleted
                try await database.pool.write { db in
                    try ClipboardRecord.cleanupMissingFiles(in: db)
                }

                // Orphan scan: remove video files with no matching DB record.
                // Catches files left behind when retention deletes video records.
                let knownHashes = try await database.pool.read { db in
                    try Set(String.fetchAll(db, sql: "SELECT contentHash FROM clipboardItem WHERE kind = 'video'"))
                }
                let videosDir = ClipboardRecord.videosDirectory
                do {
                    let files = try FileManager.default.contentsOfDirectory(
                        at: videosDir,
                        includingPropertiesForKeys: nil
                    )
                    for file in files where file.pathExtension == "mp4" {
                        let hash = file.deletingPathExtension().lastPathComponent
                        if !knownHashes.contains(hash) {
                            do {
                                try FileManager.default.removeItem(at: file)
                                Log.debug("AppDelegate: removed orphaned video \(hash.prefix(8)).mp4")
                            } catch {
                                Log.debug("AppDelegate: failed to remove orphaned video \(hash.prefix(8)): \(error)")
                            }
                        }
                    }
                } catch {
                    Log.debug("AppDelegate: orphan scan skipped — could not list videos dir: \(error)")
                }
            } catch {
                Log.error("AppDelegate: cleanup failed: \(error)")
            }
        }
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let image = NSImage(named: "MenuBarIconTemplate") {
                image.size = NSSize(width: 22, height: 22)
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Drobu")
            }
            button.setAccessibilityLabel("Drobu")
        }

        let menu = NSMenu()
        // Dynamic sleep status items need menuWillOpen/menuDidClose
        menu.delegate = self
        menu.addItem(withTitle: "Settings...", action: #selector(openPreferences), keyEquivalent: ",")
        if let controller = updaterController {
            let checkForUpdatesItem = NSMenuItem(
                title: "Check for Updates...",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            checkForUpdatesItem.target = controller
            menu.addItem(checkForUpdatesItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    /// Current sleep mode for the icon, Closed Lid taking precedence over Keep
    /// Awake (matches the historical badge-dot precedence).
    private var currentSleepMode: SleepMode {
        if closedLidService.isActive { return .closedLid }
        if caffeinateService.isActive { return .keepAwake }
        return .none
    }

    /// Single source of truth for the menu-bar icon overlays: the bottom-right
    /// sleep dot and the top-right update arrow, both rendered from the pure
    /// `StatusItemPresentation` decision so they never collide. Replaces the old
    /// refreshMenuBarBadge/updateMenuBarBadge pair (which only knew about the
    /// sleep dot).
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let updatePending = pendingUpdateVersion != nil
        let indicators = StatusItemPresentation.statusIconIndicators(
            sleepMode: currentSleepMode,
            updatePending: updatePending
        )

        if let dotColor = indicators.sleepDot {
            ensureBadgeDot(in: button, color: nsColor(for: dotColor))
        } else {
            badgeDotView?.removeFromSuperview()
            badgeDotView = nil
        }

        if indicators.showsUpdateArrow {
            ensureUpdateArrow(in: button)
        } else {
            updateArrowView?.removeFromSuperview()
            updateArrowView = nil
        }

        button.setAccessibilityLabel(
            StatusItemPresentation.statusButtonAccessibilityLabel(updatePending: updatePending)
        )
    }

    private func nsColor(for dot: SleepDotColor) -> NSColor {
        switch dot {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        }
    }

    private func ensureBadgeDot(in button: NSStatusBarButton, color: NSColor) {
        if let dot = badgeDotView {
            dot.layer?.backgroundColor = color.cgColor
        } else {
            // Bottom-right. In the status button's coordinate space y=1 is the
            // TOP edge (verified visually), so the bottom sits near maxY — this
            // keeps the sleep dot clear of the top-right update arrow.
            let dot = NSView(frame: NSRect(x: button.bounds.maxX - 7, y: button.bounds.maxY - 7, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 3
            button.addSubview(dot)
            badgeDotView = dot
        }
    }

    /// Blue down-arrow glyph in the top-right corner — deliberately `.systemBlue`
    /// (not the system accent) and a distinct shape from the sleep dot, so an
    /// available update never reads as a third sleep mode.
    private func ensureUpdateArrow(in button: NSStatusBarButton) {
        guard updateArrowView == nil else { return }
        let size: CGFloat = 9
        // Top-right. y=1 is the TOP edge in this button's coordinate space
        // (verified visually); the sleep dot sits at the bottom (near maxY).
        let arrow = NSImageView(frame: NSRect(
            x: button.bounds.maxX - size - 1,
            y: 1,
            width: size,
            height: size
        ))
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        arrow.image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "Update available"
        )?.withSymbolConfiguration(config)
        arrow.contentTintColor = .systemBlue
        arrow.imageScaling = .scaleProportionallyUpOrDown
        button.addSubview(arrow)
        updateArrowView = arrow
    }

    // MARK: - Sleep Status Menu Items

    /// Gate on isActive AND remaining > 0: CaffeinateService.isActive
    /// short-circuits on expiry, but ClosedLidService.isActive is just
    /// `state != .idle` and stays true for up to 30s after expiry
    /// (reconciliation lag) — without the remaining check the menu would
    /// show a stale "< 1 min left" line.
    private var keepAwakeShowable: Bool {
        caffeinateService.isActive && (caffeinateService.remainingTime ?? 0) > 0
    }

    private var closedLidShowable: Bool {
        closedLidService.isActive && (closedLidService.remainingTime ?? 0) > 0
    }

    /// State-derived rebuild of the status section at the top of the menu —
    /// recomputed from current service state on every call, mirroring
    /// refreshMenuBarBadge(). Skipped while the menu is tracking: structural
    /// mutation of an open NSMenu is an AppKit glitch vector, so the open-menu
    /// timer updates titles only and the rebuild happens on close.
    private func refreshSleepStatusItems() {
        guard !isMenuOpen, let menu = statusItem?.menu else { return }

        for item in sleepStatusItems where item.menu === menu {
            menu.removeItem(item)
        }
        sleepStatusItems.removeAll()
        keepAwakeStatusItem = nil
        closedLidStatusItem = nil

        var items: [NSMenuItem] = []
        // Closed Lid first — matches badge-dot precedence
        if closedLidShowable {
            let item = makeSleepStatusItem(
                name: "Closed Lid",
                remaining: closedLidService.remainingTime ?? 0,
                stopAction: #selector(stopClosedLidFromMenu),
                includeExtend: false
            )
            closedLidStatusItem = item
            items.append(item)
        }
        if keepAwakeShowable {
            let item = makeSleepStatusItem(
                name: "Keep Awake",
                remaining: caffeinateService.remainingTime ?? 0,
                stopAction: #selector(stopKeepAwakeFromMenu),
                includeExtend: true
            )
            keepAwakeStatusItem = item
            items.append(item)
        }

        guard !items.isEmpty else { return }
        items.append(.separator())
        // Sit below the update items (if any) so the update block stays at the
        // very top of the menu regardless of which state changed last. INVARIANT:
        // refreshUpdateMenuItems() must have run first so `updateMenuItems` is
        // current — both menu callers (menuWillOpen/menuDidClose) order it that
        // way; see `sleepItemInsertionBase`.
        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: sleepItemInsertionBase + index)
        }
        sleepStatusItems = items
    }

    /// Index at which sleep status items insert — directly below the update
    /// block. A derived value, not a magic number: making the dependency on
    /// `updateMenuItems` explicit so the temporal coupling with
    /// `refreshUpdateMenuItems()` is visible at the call site.
    private var sleepItemInsertionBase: Int { updateMenuItems.count }

    private func sleepStatusTitle(name: String, remaining: TimeInterval) -> String {
        "\(name) — \(SleepCommand.formatRemaining(remaining))"
    }

    private func makeSleepStatusItem(
        name: String,
        remaining: TimeInterval,
        stopAction: Selector,
        includeExtend: Bool
    ) -> NSMenuItem {
        // Parent carries no action — clicking it only opens the submenu
        // (misclick safety). The title doubles as the VoiceOver label.
        let item = NSMenuItem(
            title: sleepStatusTitle(name: name, remaining: remaining),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        let stop = NSMenuItem(title: "Stop", action: stopAction, keyEquivalent: "")
        stop.target = self
        submenu.addItem(stop)
        if includeExtend {
            let extend = NSMenuItem(
                title: "Extend 1h",
                action: #selector(extendKeepAwakeFromMenu),
                keyEquivalent: ""
            )
            extend.target = self
            submenu.addItem(extend)
        }
        item.submenu = submenu
        return item
    }

    /// Called by the 1s timer while the menu is open. Titles only — no
    /// structural add/remove during tracking. A mode that expires mid-display
    /// loses its submenu, which auto-disables the item (no action, no
    /// submenu); removal happens at the next closed-state refresh.
    private func updateSleepStatusTitles() {
        updateSleepStatusTitle(
            keepAwakeStatusItem,
            name: "Keep Awake",
            showable: keepAwakeShowable,
            remaining: caffeinateService.remainingTime
        )
        updateSleepStatusTitle(
            closedLidStatusItem,
            name: "Closed Lid",
            showable: closedLidShowable,
            remaining: closedLidService.remainingTime
        )
    }

    private func updateSleepStatusTitle(
        _ item: NSMenuItem?,
        name: String,
        showable: Bool,
        remaining: TimeInterval?
    ) {
        guard let item else { return }
        if showable, let remaining {
            item.title = sleepStatusTitle(name: name, remaining: remaining)
        } else if item.submenu != nil {
            item.submenu = nil
            item.title = "\(name) — ended"
        }
    }

    @objc private func stopKeepAwakeFromMenu() {
        Log.info("AppDelegate: menu Stop Keep Awake")
        caffeinateService.stop()
    }

    @objc private func stopClosedLidFromMenu() {
        Log.info("AppDelegate: menu Stop Closed Lid")
        Task { await closedLidService.stop() }
    }

    @objc private func extendKeepAwakeFromMenu() {
        Log.info("AppDelegate: menu Extend Keep Awake 1h")
        caffeinateService.extend(by: 3600)
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        // Rebuild while still safe (isMenuOpen not yet set), so the menu
        // opens with current state even if a change arrived while closed.
        // Update items first so the sleep items offset below them.
        refreshUpdateMenuItems()
        refreshSleepStatusItems()
        isMenuOpen = true
        guard !sleepStatusItems.isEmpty else { return }

        sleepStatusTimer?.invalidate()
        // Registered in .common mode — default-mode timers do not fire while
        // NSMenu tracking runs the loop in .eventTracking (idiom from
        // ClipboardMonitor).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateSleepStatusTitles()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        sleepStatusTimer = timer
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        sleepStatusTimer?.invalidate()
        sleepStatusTimer = nil
        isMenuOpen = false
        // Apply any state changes that arrived while the menu was open
        refreshUpdateMenuItems()
        refreshSleepStatusItems()
    }

    // MARK: - Gentle Update Reminders (Sparkle)

    // The protocol is not `@MainActor`-isolated, so each witness is declared
    // `nonisolated` and hops onto the main actor inside — keeping the conformance
    // off the @MainActor class's isolation boundary. `assumeIsolated` is safe
    // because Sparkle 2.9.1 invokes every SPUStandardUserDriverDelegate method on
    // the main thread (the suppressed-update callback is dispatched to the main
    // queue; the synchronous ones run inside main-thread-asserted driver methods).

    /// Required to opt into Sparkle's gentle scheduled-update reminders for a
    /// background (`.accessory`) app — without it Sparkle warns and falls back
    /// to its standard modal presentation.
    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Decide whether Sparkle shows its standard modal for a *scheduled* update.
    /// Returning `false` suppresses it so we surface the update gently (menu +
    /// icon) instead. We defer to Sparkle (`true`) only when it proposes
    /// immediate focus — Sparkle sets this when the app launched recently or the
    /// system has been idle, i.e. a moment the user is plausibly attentive.
    /// User-initiated "Check for Updates…" never reaches this method — it always
    /// shows the standard dialog.
    public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// Fires just before any update is presented. We light up the gentle
    /// surfaces only when WE are handling the presentation (`!handleShowingUpdate`)
    /// for a non-user-initiated update — otherwise Sparkle is already showing its
    /// own dialog (user-initiated check, or the immediate-focus scheduled path),
    /// and a second gentle indicator behind it would be redundant.
    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            guard !state.userInitiated, !handleShowingUpdate else { return }
            pendingUpdateVersion = update.displayVersionString
            Log.info("AppDelegate: gentle update pending (v\(update.displayVersionString))")
            refreshUpdateUI()
        }
    }

    /// The user engaged with the update (e.g. via our menu item resuming the
    /// install) — clear the gentle indicators.
    public nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    /// The update session ended. Clear the indicators; if the update is still
    /// uninstalled, the next scheduled check re-surfaces it.
    public nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    private func clearPendingUpdate() {
        guard pendingUpdateVersion != nil else { return }
        pendingUpdateVersion = nil
        immediateInstallBlock = nil
        Log.info("AppDelegate: gentle update indicator cleared")
        refreshUpdateUI()
    }

    // MARK: - SPUUpdaterDelegate (automatic-download path)

    /// Fires when a background auto-download (SUAutomaticallyUpdate) has staged an
    /// update for install-on-quit. This is the COMMON gentle path — it bypasses
    /// the user-driver alert callbacks above, so without it the menu row/arrow
    /// would only ever appear on the rarer alert paths. Returning `true` takes
    /// control of install timing: we keep the staged update and either install it
    /// now (user clicks "Restart to Update" → immediateInstallBlock) or on quit.
    /// Called on the main thread (Sparkle's installer driver dispatches to main).
    public nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let box = InstallBlockBox(run: immediateInstallHandler)
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            immediateInstallBlock = box.run
            pendingUpdateVersion = version
            Log.info("AppDelegate: gentle update staged for install (v\(version))")
            refreshUpdateUI()
        }
        return true
    }

    /// Refresh both gentle-update surfaces from `pendingUpdateVersion`: the
    /// status-menu items and the menu-bar icon arrow.
    private func refreshUpdateUI() {
        refreshUpdateMenuItems()
        refreshStatusIcon()
    }

    /// State-derived rebuild of the "update available" items pinned to the very
    /// top of the status menu. Mirrors `refreshSleepStatusItems`: rebuild only
    /// while the menu is closed (no structural mutation of an open NSMenu).
    /// The items are static text, so no open-menu refresh timer is needed.
    private func refreshUpdateMenuItems() {
        guard !isMenuOpen, let menu = statusItem?.menu else { return }

        for item in updateMenuItems where item.menu === menu {
            menu.removeItem(item)
        }
        updateMenuItems.removeAll()

        guard let version = pendingUpdateVersion else { return }

        // Disabled informational line — no action ⇒ auto-disabled (greyed); its
        // title doubles as the VoiceOver label.
        let info = NSMenuItem(
            title: StatusItemPresentation.menuItemTitle(version: version),
            action: nil,
            keyEquivalent: ""
        )
        info.isEnabled = false
        let restart = NSMenuItem(
            title: "Restart to Update",
            action: #selector(restartToUpdate),
            keyEquivalent: ""
        )
        restart.target = self
        let separator = NSMenuItem.separator()

        // Insert at the very top, above any sleep status items.
        menu.insertItem(separator, at: 0)
        menu.insertItem(restart, at: 0)
        menu.insertItem(info, at: 0)
        updateMenuItems = [info, restart, separator]
    }

    @objc private func restartToUpdate() {
        // Guard against a stale item: if the session ended while the menu was
        // held open, the item can linger one cycle. Without this, a click would
        // start a fresh user-initiated check (the "Checking for Updates" modal
        // this feature exists to suppress) instead of resuming.
        guard pendingUpdateVersion != nil else {
            Log.info("AppDelegate: Restart to Update ignored — no pending update")
            return
        }
        if let installNow = immediateInstallBlock {
            // Automatic-download path: the update is already staged — install and
            // relaunch immediately, no UI (Sparkle's immediate-install handler).
            Log.info("AppDelegate: installing staged update immediately")
            installNow()
        } else {
            // Alert path (impatient/critical/authorization): resume via the updater,
            // which re-presents Sparkle's Install & Relaunch.
            Log.info("AppDelegate: user chose Restart to Update — resuming via updater")
            updaterController?.checkForUpdates(nil)
        }
    }

    @objc private func openPreferences() {
        showSettings()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Defensive: release the recording-scoped Esc claim even if a capture
        // was mid-flight — a leaked global Esc hotkey would be a system-wide
        // Esc blackhole (process exit unregisters anyway; this is explicit).
        escStopHotKey = nil
        caffeinateService.cleanup()
        closedLidService.cleanup()
    }

    // MARK: - Closed Lid Daemon Alerts

    private func showDaemonApprovalAlert() {
        let alert = NSAlert()
        alert.messageText = "Approve Drobu's Closed Lid Helper"
        alert.informativeText = """
            Closed Lid mode needs a one-time approval. Open System Settings → \
            Login Items, find Drobu's helper under "Allow in the Background", and \
            turn it on. On managed Macs your administrator may need to allow it.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            DaemonRegistrar().openApprovalSettings()
        }
    }

    private func showClosedLidFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Closed Lid"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN) // Ignore default handling so DispatchSource can catch it
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.closedLidService.cleanup()
                    self?.caffeinateService.cleanup()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Settings panel (first-run setup + ongoing settings)

    /// Auto-show the welcome + permission checklist on first launch only.
    private func showSettingsIfFirstRun() {
        guard onboardingGate.shouldAutoShow else { return }
        showSettings()
    }

    /// Show (or re-show) the unified Settings panel. Recreated each time —
    /// NSHostingView `onAppear` is unreliable and the panel owns a live-refresh
    /// timer it must re-arm. First run lands on Set Up (welcome + CTA);
    /// afterwards it lands on Shortcuts. Reuses the launch-baselined
    /// `PermissionsService` so the restart-pending status stays accurate.
    private func showSettings() {
        // The service is created early in applicationDidFinishLaunching; if it's
        // somehow absent, bail rather than spinning up a fresh one whose launch
        // baseline is wrong (it would false-green a just-granted restart perm).
        guard let permissions = permissionsService else { return }
        // Reuse an already-open panel — re-fronting it rather than
        // close()+recreate avoids the recreate path's close() marking the
        // onboarding gate complete mid-first-run (a second Settings invocation
        // must not silently consume onboarding). `firstRun` is captured at
        // creation, so the open panel keeps its mode.
        if let panel = settingsPanel {
            panel.show()
            return
        }
        let firstRun = onboardingGate.shouldAutoShow
        let panel = SettingsPanel(
            permissions: permissions,
            gate: onboardingGate,
            firstRun: firstRun,
            onClose: { [weak self] in self?.settingsPanel = nil }
        )
        settingsPanel = panel
        panel.show()
    }

    // MARK: - Hotkey Management

    private func registerHotkey(_ combo: KeyCombo) {
        hotKey = nil // unregister old
        hotKey = HotKey(keyCombo: combo)
        hotKey?.keyDownHandler = { [weak self] in
            self?.togglePanel()
        }
    }

    private func registerCaptureHotkey(_ combo: KeyCombo) {
        captureHotKey = nil
        captureHotKey = HotKey(keyCombo: combo)
        captureHotKey?.keyDownHandler = { [weak self] in
            self?.handleCaptureHotkey()
        }
    }

    private func registerVideoCaptureHotkey(_ combo: KeyCombo) {
        videoCaptureHotKey = nil
        videoCaptureHotKey = HotKey(keyCombo: combo)
        videoCaptureHotKey?.keyDownHandler = { [weak self] in
            self?.handleVideoCaptureHotkey()
        }
    }

    // MARK: - Recording-Scoped Esc Stop Hotkey

    /// Claims plain Esc as a global stop hotkey only while a recording is
    /// active. Carbon hotkeys are system-wide and consume the keypress, so
    /// the claim must exist only during recording — never while idle,
    /// selecting (the selection panel handles Esc locally), or
    /// encoding/finalizing.
    ///
    /// State-derived, not transition-derived: both services' onStateChange
    /// callbacks funnel here, and the claim is recomputed from current state
    /// each time — idempotent and order-independent, so callback interleaving
    /// and async transitions cannot leak a stale claim.
    private func refreshEscStopHotkey() {
        let active = CaptureUIPolicy.escClaimActive(
            gif: captureService?.state ?? .idle,
            video: videoCaptureService?.state ?? .idle
        )
        if active {
            guard escStopHotKey == nil else { return }
            let hotKey = HotKey(keyCombo: KeyCombo(key: .escape, modifiers: []))
            hotKey.keyDownHandler = { [weak self] in
                // Stop only — teardown happens via the state callback the stop
                // flow triggers. Never touch escStopHotKey from this handler.
                self?.stopActiveRecording()
            }
            escStopHotKey = hotKey
            Log.info("AppDelegate: Esc stop hotkey claimed")
        } else if escStopHotKey != nil {
            escStopHotKey = nil
            Log.info("AppDelegate: Esc stop hotkey released")
        }
    }

    /// Stops whichever capture service is actively recording (shared by the
    /// always-on Cmd+Esc hotkey and the recording-scoped plain-Esc hotkey).
    /// stopRecording()'s `guard state == .recording` makes double-fire a no-op.
    private func stopActiveRecording() {
        if captureService?.state == .recording {
            captureService?.stopRecording()
        } else if videoCaptureService?.state == .recording {
            videoCaptureService?.stopRecording()
        }
    }

    // MARK: - Screen Capture

    private func handleCaptureHotkey() {
        guard let service = captureService else { return }
        guard videoCaptureService?.state == .idle else { return } // Mutual exclusion
        switch service.state {
        case .idle:
            // License gate, mirroring showPanel(): block STARTING a capture
            // once the trial has expired. Only the .idle→start transition is
            // gated — stop/cancel below stay reachable so a recording begun
            // in-trial can still be finished. (mgr nil only in dev builds.)
            if let mgr = licenseManager, !CaptureUIPolicy.captureStartAllowed(license: mgr.status) {
                showActivationPanel(licenseManager: mgr)
                return
            }
            if panel?.isVisible == true { togglePanel() }
            service.startRegionSelection()
        case .selecting:
            service.cancelSelection()
        case .recording:
            service.stopRecording()
        case .encoding:
            break
        }
    }

    private func handleCaptureComplete(_ gifData: Data) {
        Log.debug("AppDelegate: screen capture complete, \(gifData.count / 1024)KB")
        let hash = gifData.sha256String
        let record = ClipboardRecord(
            kind: ClipboardRecord.kindGif,
            plainText: ClipboardRecord.mediaDisplayText(from: gifData, kind: ClipboardRecord.kindGif),
            imageData: gifData,
            sourceApp: "Screen Capture",
            sourceBundleId: Bundle.main.bundleIdentifier,
            contentHash: hash,
            createdAt: Date()
        )

        // Save to database
        guard let db = database else { return }
        Task.detached {
            do {
                _ = try await db.pool.write { dbConn in
                    try ClipboardRecord.upsert(record, in: dbConn)
                }
            } catch {
                Log.error("AppDelegate: capture upsert failed: \(error)")
            }
        }

        // Write to pasteboard (GIF primary, PNG fallback)
        monitor?.suppressNextChange()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        FloatingPanel.writeGIFToPasteboard(gifData, pasteboard: pasteboard)
    }

    // MARK: - Video Capture

    private func handleVideoCaptureHotkey() {
        guard let service = videoCaptureService else { return }
        guard captureService?.state == .idle else { return } // Mutual exclusion
        switch service.state {
        case .idle:
            // License gate, mirroring showPanel(): block STARTING a capture
            // once the trial has expired. Only the .idle→start transition is
            // gated — stop/cancel below stay reachable so a recording begun
            // in-trial can still be finished. (mgr nil only in dev builds.)
            if let mgr = licenseManager, !CaptureUIPolicy.captureStartAllowed(license: mgr.status) {
                showActivationPanel(licenseManager: mgr)
                return
            }
            if panel?.isVisible == true { togglePanel() }
            service.startRegionSelection()
        case .selecting:
            service.cancelSelection()
        case .recording:
            service.stopRecording()
        case .finalizing:
            break
        }
    }

    private func handleVideoCaptureComplete(videoURL: URL, thumbnail: Data, duration: TimeInterval) {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let formatted = String(format: "%d:%02d", minutes, seconds)
        Log.debug("AppDelegate: video capture complete — \(formatted)")

        // Read content hash from the filename (already computed by VideoCaptureService)
        let hash = videoURL.deletingPathExtension().lastPathComponent

        let record = ClipboardRecord(
            kind: ClipboardRecord.kindVideo,
            plainText: "Screen Recording (\(formatted))",
            imageData: thumbnail.isEmpty ? nil : thumbnail,
            sourceApp: "Screen Capture",
            sourceBundleId: Bundle.main.bundleIdentifier,
            contentHash: hash,
            createdAt: Date()
        )

        guard let db = database else { return }
        Task.detached {
            do {
                _ = try await db.pool.write { dbConn in
                    try ClipboardRecord.upsert(record, in: dbConn)
                }
            } catch {
                Log.error("AppDelegate: video capture upsert failed: \(error)")
            }
        }

        // Write file URL to pasteboard
        monitor?.suppressNextChange()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([videoURL as NSURL])
    }

    // MARK: - Pasteboard Privacy (macOS 15.4+)

    func checkPasteboardPrivacy() {
        // macOS 15.4+ introduces pasteboard privacy. Only prompt when access is
        // actually restricted (granted == false); nil means the OS is < 15.4.
        guard NSPasteboard.general.drobuAccessGranted == false else { return }

        let alert = NSAlert()
        alert.messageText = "Clipboard Access Required"
        alert.informativeText = "Drobu needs permission to read the clipboard. Please grant access in System Settings > Privacy & Security > Pasteboard."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemPrivacyPane("Privacy_Pasteboard")
        }
    }
}
