import Foundation

/// In-app software updates, behind a protocol so `DrobuCore` carries no updater
/// dependency of its own.
///
/// This exists for one hard reason: an App Store build may not merely *avoid*
/// using Sparkle, it may not **link** it — Guideline 2.4.5(vii) requires apps to
/// use the App Store for updates, and "other update mechanisms are not allowed".
/// A `#if` around the call sites would not have been enough, because Sparkle was
/// a dependency of `DrobuCore` and `AppDelegate` conformed to two of its delegate
/// protocols directly, so every executable linking the core linked Sparkle too.
/// The implementation therefore lives in its own target (`DrobuUpdater`) that
/// only the direct-sale executable depends on.
///
/// The direct build supplies `SparkleUpdateCoordinator`; the Mac App Store build
/// supplies nothing, and `AppDelegate` simply has no updater — no menu item, no
/// badge, no checks.
@MainActor
public protocol UpdateCoordinating: AnyObject {
    /// Fires whenever a waiting update appears or is cleared. The argument is the
    /// human-readable version of the update, or `nil` when nothing is pending.
    ///
    /// The owner mirrors this into its own UI state rather than polling, because
    /// the underlying updater pushes: an update can be staged by a background
    /// download with no user interaction at all.
    var onPendingUpdateChange: ((String?) -> Void)? { get set }

    /// The version of the update currently waiting, or `nil`.
    var pendingVersion: String? { get }

    /// Begin background update checking. Called once, at launch.
    func start()

    /// The user explicitly asked to check (the "Check for Updates…" menu item).
    /// Always presents the updater's own UI, even when a gentle indicator is up.
    func checkForUpdates()

    /// The user chose "Restart to Update". Installs a staged update immediately
    /// when one is held, otherwise resumes whatever presentation the updater
    /// needs to finish the job.
    func installPendingUpdate()
}

/// How the executable hands its updater to `AppDelegate`.
///
/// `AppDelegate` is instantiated by SwiftUI's `@NSApplicationDelegateAdaptor`, so
/// it cannot take the updater as an init parameter. The executable target sets
/// this before the app finishes launching; `AppDelegate` reads it once in
/// `applicationDidFinishLaunching`.
///
/// **Leaving it unset is the Mac App Store configuration**, not an error: no
/// factory means no updater, which is exactly what that build requires.
public enum UpdaterFactory {
    @MainActor public static var make: (() -> UpdateCoordinating)?
}
