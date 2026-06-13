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

extension NSPasteboard {
    /// macOS 15.4+ pasteboard access state, read non-mutatingly via the
    /// `accessBehavior` KVC value (the SDK may lack the declaration). `true` when
    /// access is granted (`accessBehavior == 0`, unrestricted), `false` when
    /// restricted/denied, and `nil` when the property is absent (macOS < 15.4).
    /// Reading this never triggers the per-access "Allow paste" system alert.
    var drobuAccessGranted: Bool? {
        guard responds(to: NSSelectorFromString("accessBehavior")) else { return nil }
        let raw = value(forKey: "accessBehavior") as? Int ?? 0
        return raw == 0
    }
}
