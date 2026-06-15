import Foundation

/// Pure verdict → user-facing copy. Extracted from the SwiftUI views so the
/// wording (the part with logic — pluralization, the device list) is
/// unit-testable; the views stay declarative shells.
public enum ActivationCopy {
    /// Cap reached. `deviceCount` is the number of currently-activated Macs.
    public static func overCapTitle() -> String {
        "You've reached the device limit"
    }

    public static func overCapMessage(deviceCount: Int) -> String {
        let macs = deviceCount == 1 ? "1 Mac" : "\(deviceCount) Macs"
        return "Your license is active on \(macs) — the maximum. To use Drobu here, "
            + "open one of those other Macs, go to Settings → License → "
            + "\u{201C}Deactivate this Mac\u{201D}, then come back here and tap "
            + "\u{201C}Check again\u{201D}."
    }

    public static let revokedTitle = "This license was refunded"

    public static var revokedMessage: String {
        "This license was refunded and is no longer active. If you believe this is "
            + "a mistake, contact \(PurchaseLinks.supportEmail)."
    }

    /// One row in the activated-device list ("Daniel's MacBook — activated Jun 3").
    public static func deviceLine(_ device: ActivatedDevice) -> String {
        let when = deviceDateFormatter.string(from: device.activatedAt)
        return "\(device.name) — activated \(when)"
    }

    private static let deviceDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
