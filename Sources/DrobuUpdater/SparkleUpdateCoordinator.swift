import DrobuCore
import Foundation
import Sparkle

/// Ferries Sparkle's non-Sendable install block across the `nonisolated` →
/// main-actor hop in `updater(_:willInstallUpdateOnQuit:…)`. Safe as
/// `@unchecked Sendable` because the block is received, stored, and invoked
/// only on the main thread (Sparkle's installer driver dispatches to main).
private struct InstallBlockBox: @unchecked Sendable {
    let run: () -> Void
}

/// Sparkle-backed updates for the direct-sale build.
///
/// This is the whole reason `DrobuUpdater` is a separate target: an App Store
/// build may not link Sparkle at all, and this type conforms to two Sparkle
/// delegate protocols, so it cannot live in `DrobuCore`.
///
/// The behaviour here is unchanged from when it lived in `AppDelegate`, and the
/// rules it encodes are load-bearing — each was paid for with a shipped bug. See
/// `.claude/rules/sparkle-macos-gotchas.md`. In particular:
///
/// - **Both delegates are required.** With `SUAutomaticallyUpdate` on, the common
///   scheduled check runs through `SPUAutomaticUpdateDriver`, which downloads
///   silently and calls `SPUUpdaterDelegate.willInstallUpdateOnQuit` — it does NOT
///   call the user-driver alert callbacks. A gentle UI wired only to the user
///   driver therefore never fires in the common case.
/// - **The witnesses are `nonisolated` + `assumeIsolated`.**
///   `SPUStandardUserDriverDelegate` is not `@MainActor`, so conforming a
///   `@MainActor` type to it fails the Swift 6 build. Sparkle 2.9.1 invokes all of
///   these on the main thread, which is what makes `assumeIsolated` sound.
@MainActor
public final class SparkleUpdateCoordinator: NSObject, UpdateCoordinating,
    SPUStandardUserDriverDelegate, SPUUpdaterDelegate {

    public var onPendingUpdateChange: ((String?) -> Void)?

    public private(set) var pendingVersion: String? {
        didSet {
            guard pendingVersion != oldValue else { return }
            onPendingUpdateChange?(pendingVersion)
        }
    }

    private var controller: SPUStandardUpdaterController?
    /// Set only on the automatic-download path, where Sparkle hands us a block
    /// that installs the already-staged update and relaunches with no UI.
    private var immediateInstallBlock: (() -> Void)?

    public override init() {
        super.init()
    }

    // MARK: - UpdateCoordinating

    public func start() {
        // We are BOTH delegates so updates are surfaced gently (status menu +
        // icon arrow) instead of a modal, on both Sparkle paths: the updater
        // delegate catches the common silent auto-download (install-on-quit),
        // and the user-driver delegate catches the alert paths
        // (impatient/critical/authorization).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        Log.info("SparkleUpdateCoordinator: Sparkle updater started")
    }

    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    public func installPendingUpdate() {
        // Guard against a stale invocation: if the session ended while the menu
        // was held open, the item can linger one cycle. Without this, a click
        // would start a fresh user-initiated check (the "Checking for Updates"
        // modal this feature exists to suppress) instead of resuming.
        guard pendingVersion != nil else {
            Log.info("SparkleUpdateCoordinator: install ignored — no pending update")
            return
        }
        if let installNow = immediateInstallBlock {
            // Automatic-download path: the update is already staged — install and
            // relaunch immediately, no UI (Sparkle's immediate-install handler).
            Log.info("SparkleUpdateCoordinator: installing staged update immediately")
            installNow()
        } else {
            // Alert path (impatient/critical/authorization): resume via the
            // updater, which re-presents Sparkle's Install & Relaunch.
            Log.info("SparkleUpdateCoordinator: resuming update via updater")
            controller?.checkForUpdates(nil)
        }
    }

    private func clearPendingUpdate() {
        guard pendingVersion != nil else { return }
        pendingVersion = nil
        immediateInstallBlock = nil
        Log.info("SparkleUpdateCoordinator: gentle update indicator cleared")
    }

    // MARK: - Gentle Update Reminders (SPUStandardUserDriverDelegate)

    /// Required to opt into Sparkle's gentle scheduled-update reminders for a
    /// background (`.accessory`) app — without it Sparkle warns and falls back
    /// to its standard modal presentation.
    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Decide whether Sparkle shows its standard modal for a *scheduled* update.
    /// Returning `false` suppresses it so we surface the update gently (menu +
    /// icon) instead. We defer to Sparkle (`true`) only when it proposes
    /// immediate focus — Sparkle sets this when the app launched recently or the
    /// system has been idle, i.e. a moment the user is plausibly attentive.
    /// User-initiated "Check for Updates…" never reaches this method — it always
    /// shows the standard dialog.
    public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// Fires just before any update is presented. We light up the gentle
    /// surfaces only when WE are handling the presentation (`!handleShowingUpdate`)
    /// for a non-user-initiated update — otherwise Sparkle is already showing its
    /// own dialog (user-initiated check, or the immediate-focus scheduled path),
    /// and a second gentle indicator behind it would be redundant.
    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            guard !state.userInitiated, !handleShowingUpdate else { return }
            pendingVersion = update.displayVersionString
            Log.info("SparkleUpdateCoordinator: gentle update pending (v\(update.displayVersionString))")
        }
    }

    /// The user engaged with the update (e.g. via our menu item resuming the
    /// install) — clear the gentle indicators.
    public nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    /// The update session ended. Clear the indicators; if the update is still
    /// uninstalled, the next scheduled check re-surfaces it.
    public nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    // MARK: - Automatic-download path (SPUUpdaterDelegate)

    /// Fires when a background auto-download (SUAutomaticallyUpdate) has staged an
    /// update for install-on-quit. This is the COMMON gentle path — it bypasses
    /// the user-driver alert callbacks above, so without it the menu row/arrow
    /// would only ever appear on the rarer alert paths. Returning `true` takes
    /// control of install timing: we keep the staged update and either install it
    /// now (user clicks "Restart to Update" → immediateInstallBlock) or on quit.
    /// Called on the main thread (Sparkle's installer driver dispatches to main).
    public nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let box = InstallBlockBox(run: immediateInstallHandler)
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            immediateInstallBlock = box.run
            pendingVersion = version
            Log.info("SparkleUpdateCoordinator: gentle update staged for install (v\(version))")
        }
        return true
    }
}
