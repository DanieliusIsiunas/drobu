import AppKit
import HotKey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var database: AppDatabase!
    private var monitor: ClipboardMonitor?
    private var panel: FloatingPanel?
    private var hotKey: HotKey?

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
        monitor?.start()

        // Register global hotkey: Cmd+Shift+V
        hotKey = HotKey(key: .v, modifiers: [.command, .shift])
        hotKey?.keyDownHandler = { [weak self] in
            self?.togglePanel()
        }

        // Run cleanup on launch
        Task.detached { [database] in
            try? await database!.pool.write { db in
                try ClipboardRecord.cleanup(in: db)
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
}
