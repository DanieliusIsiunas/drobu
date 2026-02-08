import SwiftUI

@main
struct ClipboardHistoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Clipboard History", systemImage: "clipboard") {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            Text("Settings placeholder")
                .frame(width: 300, height: 200)
        }
    }
}
