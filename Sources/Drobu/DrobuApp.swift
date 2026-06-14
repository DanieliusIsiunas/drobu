import SwiftUI
import DrobuCore

@main
struct DrobuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Inert placeholder — Drobu is a menu-bar (.accessory) app whose entire
        // UI is owned by AppDelegate (the status item + the floating Settings
        // panel). The status menu's "Settings…" item (⌘,) opens that panel
        // directly via the delegate, so this scene is never presented. A SwiftUI
        // App still requires one Scene; EmptyView() is the minimal no-op (no
        // window, no Settings-scene activation-policy dance).
        Settings { EmptyView() }
    }
}
