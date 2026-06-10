import Foundation

/// What the daemon should do on start (or after any restart/reboot), given the
/// persisted state, the current `SleepDisabled` reading, and `now`. The daemon
/// executes the action against real `pmset` + the watchdog; the decision itself
/// is pure so the full table is unit-tested without wall-clock sleeps.
public enum ReconcileAction: Equatable, Sendable {
    /// State says a session is live but `SleepDisabled` is off (e.g. it did not
    /// survive a reboot) → re-apply `disablesleep 1` and arm to the ORIGINAL
    /// absolute deadline.
    case reapplyDisableSleepAndArm(deadline: Date)
    /// State says a session is live and `SleepDisabled` is already on → arm the
    /// watchdog to the absolute deadline only.
    case armWatchdogOnly(deadline: Date)
    /// Expired / orphaned / untrusted → `disablesleep 0` and clear state.
    case reverseAndClear
    /// Nothing persisted and sleep is not disabled → no-op.
    case noop
}

public enum Reconciliation {
    /// The U4 reconciliation decision table, enumerated:
    ///  - no state, SleepDisabled on  → orphan → reverse
    ///  - no state, SleepDisabled off → no-op
    ///  - state, deadline past (any)  → reverse + clear
    ///  - state, untrusted future deadline → treat as orphan → reverse
    ///  - state, future, SleepDisabled off → re-apply + arm (post-reboot if the
    ///    setting did not persist; harmless if it did, since then it reads on)
    ///  - state, future, SleepDisabled on  → arm only
    public static func decide(state: SleepSessionState?, sleepDisabled: Bool, now: Date) -> ReconcileAction {
        guard let state else {
            return sleepDisabled ? .reverseAndClear : .noop
        }
        // Tampered/future-dated deadline beyond what a legitimate enable could
        // produce → distrust → reverse (do not adopt it).
        guard state.isDeadlineTrustworthy(now: now) else {
            return .reverseAndClear
        }
        if state.isExpired(now: now) {
            return .reverseAndClear
        }
        return sleepDisabled
            ? .armWatchdogOnly(deadline: state.deadline)
            : .reapplyDisableSleepAndArm(deadline: state.deadline)
    }
}
