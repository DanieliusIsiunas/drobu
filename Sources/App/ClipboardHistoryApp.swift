@preconcurrency import ObjectiveC
import SwiftUI

extension Notification.Name {
    static let openSettingsFromMenu = Notification.Name("openSettingsFromMenu")
}

@main
struct ClipboardHistoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Settings Opener", id: "settings-opener") {
            SettingsOpenerView()
                .frame(width: 0, height: 0)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Clipboard History", systemImage: "clipboard") {
            Button("Preferences...") {
                NotificationCenter.default.post(name: .openSettingsFromMenu, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView()
        }
    }
}

private struct SettingsOpenerView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsFromMenu)) { _ in
                NSApp.setActivationPolicy(.regular)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    observeSettingsClose()
                }
            }
    }

    private func observeSettingsClose() {
        guard let settingsWindow = findSettingsWindow() else {
            // Settings window might not exist yet — retry once
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let settingsWindow = findSettingsWindow() {
                    addCloseObserver(for: settingsWindow)
                }
            }
            return
        }
        addCloseObserver(for: settingsWindow)
    }

    private func findSettingsWindow() -> NSWindow? {
        NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("settings") == true
                || $0.title.contains("Settings")
                || $0.title.contains("Preferences")
        })
    }

    private func addCloseObserver(for window: NSWindow) {
        // Scoped to `object: window` — fires only when this specific window closes.
        // The observer lives as long as the window; no manual removal needed.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            _ = MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
