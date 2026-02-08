import AppKit
import ApplicationServices
import HotKey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var database: AppDatabase!
    private var monitor: ClipboardMonitor?
    private var panel: FloatingPanel?
    private var hotKey: HotKey?
    private var cleanupTimer: Timer?

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

        // Register global hotkey: Cmd+Shift+V
        hotKey = HotKey(key: .v, modifiers: [.command, .shift])
        hotKey?.keyDownHandler = { [weak self] in
            self?.togglePanel()
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
        if let panel = panel, panel.isVisible {
            panel.close()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        if panel == nil {
            panel = FloatingPanel {
                ClipboardPanelView(database: self.database)
            }
        }
        panel?.showCentered()
    }

    private func runCleanup() {
        Task.detached { [database] in
            try? await database!.pool.write { db in
                try ClipboardRecord.cleanup(in: db)
            }
        }
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
