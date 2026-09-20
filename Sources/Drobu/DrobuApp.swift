import SwiftUI
import DrobuCore
import DrobuUpdater

@main
struct DrobuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // The direct-sale build ships its own updater. This is the ONLY place
        // Sparkle is wired in: `DrobuCore` has no updater dependency, so a Mac
        // App Store executable can link the same core and simply leave this unset
        // — Apple owns updates there, and Guideline 2.4.5(vii) forbids shipping
        // another mechanism. Runs before `applicationDidFinishLaunching`, which
        // is where AppDelegate reads it.
        UpdaterFactory.make = { SparkleUpdateCoordinator() }
    }

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
