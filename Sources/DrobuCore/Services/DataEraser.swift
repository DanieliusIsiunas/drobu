import Foundation

/// Erases the user's on-disk data and settings on an opt-in uninstall. Injectable
/// so it is testable against a temp directory and a throwaway `UserDefaults`
/// suite without touching real user data.
///
/// Deliberately distinct from `SettingsView`'s "Delete all history" (which deletes
/// rows + video files but keeps the database file and settings so the running app
/// stays usable). This wipe removes the entire Application Support directory
/// (`clipboard.sqlite` + `-wal`/`-shm`, `videos/`, `app.log` and rotations) and
/// the app's `UserDefaults` domain — a clean slate, run only as the app quits.
///
/// It has no Keychain/Security code path: the license/trial items are preserved
/// by design (KTD5), and the absence of any `SecItem` call here is the structural
/// guarantee behind R7.
protocol DataErasing {
    func eraseAllUserData() throws
}

struct DataEraser: DataErasing {
    private let directory: URL?
    private let defaults: UserDefaults
    private let defaultsDomain: String

    init(directory: URL? = AppPaths.appSupportDirectory,
         defaults: UserDefaults = .standard,
         defaultsDomain: String = AppPaths.bundleIdentifier) {
        self.directory = directory
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
    }

    func eraseAllUserData() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        defaults.removePersistentDomain(forName: defaultsDomain)
    }
}
