import AppKit

/// Opens a System Settings → Privacy & Security pane by identifier (e.g.
/// `"Privacy_Accessibility"`, `"Privacy_ScreenCapture"`, `"Privacy_Pasteboard"`),
/// falling back to the Settings root if the URL can't be built. Single source
/// for the deep-link string previously copied across the capture services, the
/// pasteboard-privacy alert, the old Accessibility modal, and onboarding.
func openSystemPrivacyPane(_ identifier: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(identifier)") {
        NSWorkspace.shared.open(url)
    } else if let fallback = URL(string: "x-apple.systempreferences:") {
        NSWorkspace.shared.open(fallback)
    }
}

/// Maps a raw `NSPasteboardAccessBehavior` value to Drobu's grant signal. Only
/// `alwaysAllow` is an affirmative grant — the state where programmatic reads
/// succeed *silently*. The SDK enum (verified against the macOS 15.4+ headers):
///
///   default = 0   // prompt-on-access — NOT a grant (the system may still ask)
///   ask     = 1   // always ask — NOT a grant
///   allow   = 2   // alwaysAllow — silent reads → the only true grant
///   deny    = 3   // alwaysDeny — NOT a grant
///
/// Pure + testable; the OS-availability gate (`responds(to:)`) stays in the
/// `NSPasteboard` accessor below.
func pasteboardAccessGranted(rawAccessBehavior raw: Int) -> Bool {
    raw == 2   // NSPasteboardAccessBehaviorAlwaysAllow
}

extension NSPasteboard {
    /// macOS 15.4+ pasteboard access state, read non-mutatingly via the
    /// `accessBehavior` KVC value (the SDK may lack the declaration on the build
    /// toolchain). `true` **only** when access is affirmatively granted
    /// (`alwaysAllow`); `default`/`ask`/`alwaysDeny` are all `false` (the system
    /// may still prompt or block). `nil` when the property is absent (macOS
    /// < 15.4). Reading this never triggers the per-access "Allow Paste" alert.
    var drobuAccessGranted: Bool? {
        guard responds(to: NSSelectorFromString("accessBehavior")) else { return nil }
        guard let raw = value(forKey: "accessBehavior") as? Int else { return false }
        return pasteboardAccessGranted(rawAccessBehavior: raw)
    }
}
