import AppKit
import ApplicationServices
import HotKey
import Sparkle

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
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
    private let caffeinateService = CaffeinateService()
    private let closedLidService = ClosedLidService()
    private var statusItem: NSStatusItem?
    private var badgeDotView: NSView?
    private var signalSources: [DispatchSourceSignal] = []
    private var updaterController: SPUStandardUpdaterController?
    public private(set) var licenseManager: LicenseManager?
    private var licenseRefreshTimer: Timer?
    private var activationPanel: ActivationPanel?

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
            if self?.captureService?.state == .recording {
                self?.captureService?.stopRecording()
            } else if self?.videoCaptureService?.state == .recording {
                self?.videoCaptureService?.stopRecording()
            }
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

        // Badge: update menu bar dot when either sleep service changes state
        caffeinateService.onStateChange = { [weak self] _ in
            self?.refreshMenuBarBadge()
        }
        closedLidService.onStateChange = { [weak self] _ in
            self?.refreshMenuBarBadge()
        }

        // Check Accessibility permission on launch
        checkAccessibilityOnLaunch()

        // Run cleanup on launch + schedule hourly
        runCleanup()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Defer cleanup while panel is visible
                guard self?.panel?.isVisible != true else { return }
                self?.runCleanup()
            }
        }

        // Startup audit: detect orphaned disablesleep state from a previous crash
        auditDisableSleep()

        // Signal handlers for SIGTERM/SIGHUP: best-effort cleanup of Closed Lid mode
        installSignalHandlers()
    }

    private func togglePanel() {
        // Ignore panel toggle while any capture is active
        if captureService?.state != .idle { return }
        if videoCaptureService?.state != .idle { return }

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

    @objc private func openPreferences() {
        NotificationCenter.default.post(name: .openSettingsFromMenu, object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        caffeinateService.cleanup()
        closedLidService.cleanup()
    }

    // MARK: - Closed Lid Startup Audit

    private func auditDisableSleep() {
        guard closedLidService.isDisableSleepActive() else { return }
        // pmset disablesleep is enabled but we have no active session.
        // This means the app crashed or was killed while Closed Lid was active.
        let daemonExists = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.clipboardhistory.disablesleep-reversal.plist")
        if daemonExists {
            Log.info("AppDelegate: orphaned disablesleep — LaunchDaemon present, will handle reversal")
        } else {
            Log.error("AppDelegate: orphaned disablesleep — no LaunchDaemon, cleanup needed on next admin auth")
        }
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

    // MARK: - Accessibility Onboarding

    private func checkAccessibilityOnLaunch() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            Drobu needs Accessibility permission to auto-paste items. \
            Without it, items will be copied to clipboard but you'll need to paste manually with Cmd+V.

            Click 'Open System Settings' and toggle on Drobu.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Skip (Copy Only)")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
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

    // MARK: - Screen Capture

    private func handleCaptureHotkey() {
        guard let service = captureService else { return }
        guard videoCaptureService?.state == .idle else { return } // Mutual exclusion
        switch service.state {
        case .idle:
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
