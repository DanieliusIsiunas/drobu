import Foundation

/// Single source of truth for the client's on-disk locations. The
/// `"ClipboardHistory"` directory name and the app bundle id were previously
/// duplicated across `AppDatabase`, `ClipboardRecord`, and `Log`; consolidating
/// them here means the uninstall data wipe (`DataEraser`) targets exactly the
/// directory the rest of the app writes to.
///
/// Distinct from the daemon's root-owned `/Library/Application Support/
/// ClipboardHistory` (`DaemonConstants.supportDirectory`) — this is the user's
/// `~/Library/Application Support/ClipboardHistory`.
enum AppPaths {
    /// The Application Support subdirectory name.
    static let directoryName = "ClipboardHistory"

    /// The app's bundle identifier — also its `UserDefaults` suite name.
    static let bundleIdentifier = "com.danielius.ClipboardHistory"

    /// `~/Library/Application Support/ClipboardHistory`, or nil when Application
    /// Support cannot be resolved (sandbox/edge cases).
    static var appSupportDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}
