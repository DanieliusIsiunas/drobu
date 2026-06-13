import AppKit
import ApplicationServices
import HotKey
import Sparkle

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var onboardingPanel: OnboardingPanel?

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
        // boundary transitions to .trialExpired without user input.
        licenseRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { LicenseManager.shared.refresh() }
        }

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

        // Start Sparkle auto-update checks
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        Log.info("AppDelegate: Sparkle updater started")

        // Set up menu bar status item with custom icon
        setupStatusItem()

        // Badge + status menu items: update when either sleep service changes state
        caffeinateService.onStateChange = { [weak self] _ in
            self?.refreshMenuBarBadge()
            self?.refreshSleepStatusItems()
        }
        closedLidService.onStateChange = { [weak self] _ in
            self?.refreshMenuBarBadge()
            self?.refreshSleepStatusItems()
        }

        // First launch: welcome the user and let them set up permissions up
        // front (replaces the old every-launch Accessibility modal — onboarding
        // owns first-run, and later lapses degrade gracefully in-context).
        showOnboardingIfFirstRun()

        // Re-open onboarding on demand from Settings → "Setup & Permissions".
        _ = NotificationCenter.default.addObserver(
            forName: .openOnboardingRequested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
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

        // Hard gate: when the trial has expired and no license is active,
        // route to the activation panel instead of the clipboard panel.
        // The clipboard monitor keeps running in the background so when
        // the user activates, their captured data is intact.
        if let mgr = licenseManager, mgr.status == .trialExpired {
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
        menu.addItem(withTitle: "Set Up Drobu…", action: #selector(showOnboardingFromMenu), keyEquivalent: "")
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

    enum SleepMode {
        case none
        case keepAwake
        case closedLid
    }

    private func refreshMenuBarBadge() {
        let mode: SleepMode
        if closedLidService.isActive {
            mode = .closedLid
        } else if caffeinateService.isActive {
            mode = .keepAwake
        } else {
            mode = .none
        }
        updateMenuBarBadge(mode: mode)
    }

    private func updateMenuBarBadge(mode: SleepMode) {
        guard let button = statusItem?.button else { return }
        switch mode {
        case .none:
            badgeDotView?.removeFromSuperview()
            badgeDotView = nil
        case .keepAwake:
            ensureBadgeDot(in: button, color: .systemGreen)
        case .closedLid:
            ensureBadgeDot(in: button, color: .systemOrange)
        }
    }

    private func ensureBadgeDot(in button: NSStatusBarButton, color: NSColor) {
        if let dot = badgeDotView {
            dot.layer?.backgroundColor = color.cgColor
        } else {
            let dot = NSView(frame: NSRect(x: button.bounds.maxX - 7, y: 1, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 3
            button.addSubview(dot)
            badgeDotView = dot
        }
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
        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: index)
        }
        sleepStatusItems = items
    }

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
        refreshSleepStatusItems()
    }

    @objc private func openPreferences() {
        NotificationCenter.default.post(name: .openSettingsFromMenu, object: nil)
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

    // MARK: - Onboarding

    /// Auto-show the welcome + permission checklist on first launch only.
    private func showOnboardingIfFirstRun() {
        guard OnboardingGate().shouldAutoShow else { return }
        showOnboarding()
    }

    /// Show (or re-show) the onboarding panel. Recreated each time — NSHostingView
    /// `onAppear` is unreliable and the panel owns a live-refresh timer it must
    /// re-arm. Reuses the launch-baselined `PermissionsService` so the
    /// restart-pending status stays accurate.
    private func showOnboarding() {
        let permissions = permissionsService ?? PermissionsService()
        permissionsService = permissions
        onboardingPanel?.close()
        onboardingPanel = OnboardingPanel(
            permissions: permissions,
            gate: OnboardingGate(),
            onClose: { [weak self] in self?.onboardingPanel = nil }
        )
        onboardingPanel?.showCentered()
    }

    @objc private func showOnboardingFromMenu() {
        showOnboarding()
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
        // macOS 15.4+ introduces pasteboard privacy. Use runtime check since SDK may lack declarations.
        let pb = NSPasteboard.general
        guard pb.responds(to: NSSelectorFromString("accessBehavior")) else { return }
        // accessBehavior == 0 means unrestricted; anything else means restricted/denied
        guard let rawValue = pb.value(forKey: "accessBehavior") as? Int, rawValue != 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Clipboard Access Required"
        alert.informativeText = "Drobu needs permission to read the clipboard. Please grant access in System Settings > Privacy & Security > Pasteboard."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                NSWorkspace.shared.open(url)
            } else if let fallback = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(fallback)
            }
        }
    }
}
