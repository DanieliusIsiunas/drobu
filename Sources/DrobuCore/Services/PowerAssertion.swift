import Foundation
import IOKit.pwr_mgt

/// The OS power-assertion facility, behind a protocol so `CaffeinateService`'s
/// state machine is testable without touching real power management.
///
/// Replaces the previous `/usr/bin/caffeinate` subprocess. Two reasons:
/// 1. **Sandbox.** Spawning a helper binary is the one sandbox-questionable step
///    in the keep-awake path; `IOPMAssertionCreateWithProperties` is the
///    documented, App-Sandbox-compatible API (and the one App Store keep-awake
///    apps ship).
/// 2. **No orphan.** A `caffeinate` child outlives a crashed parent until its
///    `-t` elapses, leaving the Mac awake with no owner to reverse it. Power
///    assertions are owned by *this* process and released by the kernel when it
///    dies, so a crash can never strand them.
protocol PowerAssertionHolding: AnyObject {
    /// Take assertions preventing display sleep and idle system sleep for
    /// `duration`. Returns `false` if the OS refused — the caller must not
    /// enter an active session, because nothing is holding the Mac awake.
    func hold(duration: TimeInterval, reason: String) -> Bool

    /// Release any held assertions. Idempotent — safe to call when nothing is held.
    func release()

    var isHeld: Bool { get }
}

/// Real implementation over IOKit power management.
///
/// Holds two assertions to reproduce what `caffeinate -dims` did in the way a
/// user can observe: `PreventUserIdleDisplaySleep` keeps the screen lit (the
/// old `-d`) and `PreventUserIdleSystemSleep` keeps the machine from idle-sleeping
/// (the old `-i`). The old `-m` (disk idle) and `-s` (system sleep on AC) are
/// deliberately not reproduced: with the display held on, the system cannot
/// idle-sleep anyway, so neither is separately observable for a "keep awake"
/// toggle. Forced sleep (lid close, Apple menu → Sleep) still works, exactly as
/// it did with `caffeinate`.
///
/// Each assertion also carries a **kernel-enforced timeout** equal to the
/// session duration. That is a backstop, not the primary mechanism —
/// `CaffeinateService.expiryTimer` still ends the session on time so `state`
/// and the menu-bar badge clear. The timeout guarantees that even if that timer
/// somehow never fires, the Mac cannot be held awake indefinitely.
final class IOPMPowerAssertion: PowerAssertionHolding {
    private var assertionIDs: [IOPMAssertionID] = []

    private static let types: [String] = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypePreventUserIdleSystemSleep as String,
    ]

    var isHeld: Bool { !assertionIDs.isEmpty }

    func hold(duration: TimeInterval, reason: String) -> Bool {
        release()
        guard duration > 0 else { return false }

        var created: [IOPMAssertionID] = []
        for type in Self.types {
            guard let id = Self.create(type: type, duration: duration, reason: reason) else {
                // All-or-nothing: partial coverage (e.g. the display sleeps
                // while the system stays up) is a confusing half-feature, and
                // `caffeinate -dims` was all-or-nothing too. Unwind and fail.
                Log.error("IOPMPowerAssertion: failed to create \(type) — releasing partial assertions")
                created.forEach { _ = IOPMAssertionRelease($0) }
                return false
            }
            created.append(id)
        }

        assertionIDs = created
        Log.debug("IOPMPowerAssertion: held \(created.count) assertions for \(Int(duration))s")
        return true
    }

    func release() {
        guard !assertionIDs.isEmpty else { return }
        for id in assertionIDs {
            let rc = IOPMAssertionRelease(id)
            if rc != kIOReturnSuccess {
                Log.error("IOPMPowerAssertion: release failed for id \(id): \(rc)")
            }
        }
        Log.debug("IOPMPowerAssertion: released \(assertionIDs.count) assertions")
        assertionIDs = []
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
        // Not strictly required (the kernel reaps assertions with the process),
        // but keeps a discarded holder from leaving rows in `pmset -g assertions`.
        for id in assertionIDs { _ = IOPMAssertionRelease(id) }
    }
}
