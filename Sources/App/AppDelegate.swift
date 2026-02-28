import AppKit
import ApplicationServices
import HotKey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var database: AppDatabase!
    private(set) var monitor: ClipboardMonitor?
    private var panel: FloatingPanel?
    private var hotKey: HotKey?
    private var cleanupTimer: Timer?
    private var hotkeyObserver: Any?
    private var captureHotKey: HotKey?
    private var captureHotkeyObserver: Any?
    private var captureService: ScreenCaptureService?
    private let caffeinateService = CaffeinateService()
    private let closedLidService = ClosedLidService()
    private var statusItem: NSStatusItem?
    private var badgeDotView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize database
        do {
            database = try AppDatabase()
        } catch {
            NSLog("Failed to initialize database: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }

        // Start clipboard monitoring
        monitor = ClipboardMonitor(database: database)
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

        // Set up menu bar status item with custom icon
        setupStatusItem()

        // Caffeinate badge: update menu bar dot when state changes
        caffeinateService.onStateChange = { [weak self] state in
            self?.updateMenuBarBadge(isActive: state != .idle)
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
    }

    private func togglePanel() {
        // Ignore panel toggle while capture is active
        if captureService?.state != .idle { return }

        if let panel = panel, panel.isVisible {
            panel.close()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        panel?.close()
        let sleepCommand = SleepCommand(caffeinateService: caffeinateService, closedLidService: closedLidService)
        panel = FloatingPanel {
            PanelView(
                database: self.database,
                commands: [sleepCommand]
            )
        }
        panel?.showCentered()
    }

    private func runCleanup() {
        let retentionDays = RetentionDefaults.loadRetentionDays()
        let maxCount = RetentionDefaults.loadMaxItemCount()

        Task.detached { [database] in
            try? await database!.pool.write { db in
                try ClipboardRecord.cleanup(retentionDays: retentionDays, maxCount: maxCount, in: db)
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
                button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard History")
            }
            button.setAccessibilityLabel("Clipboard History")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    private func updateMenuBarBadge(isActive: Bool) {
        guard let button = statusItem?.button else { return }
        if isActive {
            if badgeDotView == nil {
                let dot = NSView(frame: NSRect(x: button.bounds.maxX - 7, y: 1, width: 6, height: 6))
                dot.wantsLayer = true
                dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                dot.layer?.cornerRadius = 3
                button.addSubview(dot)
                badgeDotView = dot
            }
        } else {
            badgeDotView?.removeFromSuperview()
            badgeDotView = nil
        }
    }

    @objc private func openPreferences() {
        NotificationCenter.default.post(name: .openSettingsFromMenu, object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        caffeinateService.cleanup()
    }

    // MARK: - Accessibility Onboarding

    private func checkAccessibilityOnLaunch() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            ClipboardHistory needs Accessibility permission to auto-paste items. \
            Without it, items will be copied to clipboard but you'll need to paste manually with Cmd+V.

            Click 'Open System Settings' and toggle on ClipboardHistory.
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

    // MARK: - Screen Capture

    private func handleCaptureHotkey() {
        guard let service = captureService else { return }
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
        let hash = gifData.sha256String
        let record = ClipboardRecord(
            kind: ClipboardRecord.kindGif,
            plainText: "Screen Capture",
            imageData: gifData,
            sourceApp: "Screen Capture",
            sourceBundleId: Bundle.main.bundleIdentifier,
            contentHash: hash,
            createdAt: Date()
        )

        // Save to database
        let db = database!
        Task.detached {
            try? await db.pool.write { dbConn in
                try ClipboardRecord.upsert(record, in: dbConn)
            }
        }

        // Write to pasteboard (GIF primary, PNG fallback)
        monitor?.suppressNextChange()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        FloatingPanel.writeGIFToPasteboard(gifData, pasteboard: pasteboard)
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
        alert.informativeText = "Clipboard History needs permission to read the clipboard. Please grant access in System Settings > Privacy & Security > Pasteboard."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
            }
        }
    }
}
