import Foundation
import IOKit.pwr_mgt

/// The OS power-assertion facility, behind a protocol so `CaffeinateService`'s
/// state machine is testable without touching real power management.
///
/// Replaces the previous `/usr/bin/caffeinate` subprocess in the Keep Awake path.
/// Two reasons:
/// 1. **Sandbox.** Spawning a helper binary is a step App Sandbox makes doubtful;
///    `IOPMAssertionCreateWithProperties` is the documented, sandbox-compatible
///    API (and the one App Store keep-awake apps ship). Note this converts the
///    Keep Awake path only — `ClosedLidService` still spawns `caffeinate -ims`,
///    and the privileged `SMAppService` daemon is a larger problem again, so the
///    sleep subsystem as a whole is NOT sandbox-clean yet.
/// 2. **No orphan.** A `caffeinate` child outlives a crashed parent until its
///    `-t` elapses, leaving the Mac awake with no owner to reverse it. Power
///    assertions are owned by *this* process and released by the kernel when it
///    dies, so a crash can never strand them.
protocol PowerAssertionHolding: AnyObject {
    /// Take the assertions that keep the Mac awake for `duration`. Returns
    /// `false` if the OS refused — the caller must not enter an active session,
    /// because nothing is holding the Mac awake.
    func hold(duration: TimeInterval, reason: String) -> Bool

    /// Release any held assertions. Idempotent — safe to call when nothing is held.
    func release()

    var isHeld: Bool { get }
}

/// Real implementation over IOKit power management.
///
/// Holds **all four** assertions `caffeinate -dims` registered, so Keep Awake is
/// unchanged from the user's point of view:
/// - `PreventUserIdleDisplaySleep` (`-d`) keeps the screen lit,
/// - `PreventUserIdleSystemSleep` (`-i`) blocks idle system sleep,
/// - `PreventSystemSleep` (`-s`) keeps the machine running in dark wake through
///   a lid close or demand sleep **while on AC**,
/// - `PreventDiskIdle` (`-m`) keeps attached disks spun up.
///
/// The full set is deliberate. This is a refactor, so any omission would be a
/// silent product change, and two of these were nearly dropped on reasoning that
/// did not survive checking: `-s` is what keeps a long transfer alive when a user
/// on AC shuts the lid (and `ClosedLidService` depends on the same assertion via
/// `caffeinate -ims`), while `-m` looks free only if you assume an SSD — an
/// external spinning volume can still idle mid-transfer. Verify against a live
/// `caffeinate -dims` in `pmset -g assertions` before changing this list; it
/// registers four rows, not two.
///
/// Each assertion also carries a **kernel-enforced timeout** equal to the session
/// duration. That is a backstop, not the primary mechanism —
/// `CaffeinateService.expiryTimer` still ends the session on time so `state` and
/// the menu-bar badge clear. The timeout guarantees that even if that timer never
/// fires, the Mac cannot be held awake indefinitely.
final class IOPMPowerAssertion: PowerAssertionHolding {
    private var assertionIDs: [IOPMAssertionID] = []

    private static let types: [String] = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypePreventUserIdleSystemSleep as String,
        kIOPMAssertionTypePreventSystemSleep as String,
        // Spelled literally on purpose. The SDK defines this one as
        // `kIOPMAssertPreventDiskIdle` (note: no `ion`/`Type`), and unlike its
        // three siblings that symbol does NOT import into Swift even though all
        // four are plain `CFSTR` defines. `IOPMLib.h` expands it to exactly this
        // string, and a live assertion using it shows up in `pmset -g assertions`
        // as `PreventDiskIdle`.
        "PreventDiskIdle",
    ]

    var isHeld: Bool { !assertionIDs.isEmpty }

    func hold(duration: TimeInterval, reason: String) -> Bool {
        release()
        guard duration > 0 else { return false }

        var created: [IOPMAssertionID] = []
        for type in Self.types {
            guard let id = Self.create(type: type, duration: duration, reason: reason) else {
                // All-or-nothing: partial coverage (e.g. the display sleeps while
                // the system stays up) is a confusing half-feature, and
                // `caffeinate -dims` was all-or-nothing too. Unwind and fail.
                //
                // Adopt what we created before unwinding so the unwind goes through
                // `release()` and inherits its retry rule. Dropping these IDs on the
                // floor here would mean a release that genuinely failed leaves an
                // assertion live with no owner left to retry it, while the session
                // reports idle — the Mac stays awake and nothing says so.
                Log.error("IOPMPowerAssertion: failed to create \(type) — releasing partial assertions")
                assertionIDs = created
                release()
                return false
            }
            created.append(id)
        }

        assertionIDs = created
        Log.debug("IOPMPowerAssertion: held \(created.count) assertions for \(Int(duration))s")
        return true
    }

    /// Releases every held assertion, **keeping any the kernel genuinely refused to
    /// release** so a later `release()`, the next `hold()`, or `deinit` can retry.
    /// Discarding a failed ID would strand a live OS assertion with no owner —
    /// bounded by the kernel timeout, but invisible until it expires.
    func release() {
        guard !assertionIDs.isEmpty else { return }
        var unreleased: [IOPMAssertionID] = []
        for id in assertionIDs {
            let rc = IOPMAssertionRelease(id)
            if rc == kIOReturnSuccess || Self.isAlreadyReleased(rc) { continue }
            Log.error("IOPMPowerAssertion: release failed for id \(id): \(rc) — retaining for retry")
            unreleased.append(id)
        }
        Log.debug("IOPMPowerAssertion: released \(assertionIDs.count - unreleased.count) assertions")
        assertionIDs = unreleased
    }

    /// `kIOReturnBadArgument` is what the kernel returns for an assertion ID it has
    /// already dropped, and that is the **normal** outcome on the healthiest path:
    /// a session allowed to run to its deadline is released by powerd at the exact
    /// instant the kernel timeout fires, and `expiryTimer` can only fire at-or-after
    /// that instant. Treating it as an error put two `ERROR` lines in `app.log` for
    /// every session that behaved perfectly, while a session stopped *early* stayed
    /// silent — signal exactly inverted. `app.log` is the first step in this
    /// project's debugging runbook, so that noise is expensive (verified live: a
    /// post-timeout release returns 0xE00002C2).
    ///
    /// Any other non-success code is still a real failure and still logged.
    static func isAlreadyReleased(_ rc: IOReturn) -> Bool {
        rc == kIOReturnBadArgument || rc == kIOReturnNotFound
    }

    private static func create(type: String, duration: TimeInterval, reason: String) -> IOPMAssertionID? {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionNameKey as String: reason,
            kIOPMAssertionLevelKey as String: Int(kIOPMAssertionLevelOn),
            kIOPMAssertionTimeoutKey as String: duration,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
        ]
        var id = IOPMAssertionID(0)
        let rc = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard rc == kIOReturnSuccess else { return nil }
        return id
    }

    deinit {
        // Not strictly required (the kernel reaps assertions with the process, and
        // stop()/cleanup() already release), but keeps a discarded holder from
        // leaving rows in `pmset -g assertions`.
        for id in assertionIDs { _ = IOPMAssertionRelease(id) }
    }
}
