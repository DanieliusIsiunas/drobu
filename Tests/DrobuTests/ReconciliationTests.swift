import Foundation
import Testing
@testable import DrobuShared

/// Exercises every cell of the U4 reconciliation decision table (the daemon's
/// boot-time safety guarantee). Pure function, injected `now`, no wall clock.
@Suite("Reconciliation")
struct ReconciliationTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func state(deadlineOffset: TimeInterval) -> SleepSessionState {
        SleepSessionState(
            deadline: now.addingTimeInterval(deadlineOffset),
            startedAt: now,
            accumulatedActiveSeconds: 0,
            accumulatorUpdatedAt: now
        )
    }

    @Test("no state + SleepDisabled on → orphan → reverse")
    func orphanReversed() {
        #expect(Reconciliation.decide(state: nil, sleepDisabled: true, now: now) == .reverseAndClear)
    }

    @Test("no state + SleepDisabled off → no-op")
    func cleanIdle() {
        #expect(Reconciliation.decide(state: nil, sleepDisabled: false, now: now) == .noop)
    }

    @Test("live session + SleepDisabled off → re-apply disablesleep + arm to original deadline")
    func liveButSleepNotDisabled() {
        let s = state(deadlineOffset: 1800)
        #expect(Reconciliation.decide(state: s, sleepDisabled: false, now: now)
                == .reapplyDisableSleepAndArm(deadline: s.deadline))
    }

    @Test("live session + SleepDisabled on → arm watchdog only")
    func liveAndSleepDisabled() {
        let s = state(deadlineOffset: 1800)
        #expect(Reconciliation.decide(state: s, sleepDisabled: true, now: now)
                == .armWatchdogOnly(deadline: s.deadline))
    }

    @Test("expired session is reversed regardless of SleepDisabled")
    func expiredReversed() {
        #expect(Reconciliation.decide(state: state(deadlineOffset: -1), sleepDisabled: true, now: now) == .reverseAndClear)
        #expect(Reconciliation.decide(state: state(deadlineOffset: -1), sleepDisabled: false, now: now) == .reverseAndClear)
        // Exactly-expired (deadline == now) counts as expired.
        #expect(Reconciliation.decide(state: state(deadlineOffset: 0), sleepDisabled: true, now: now) == .reverseAndClear)
    }

    @Test("tampered future-dated deadline is distrusted and reversed")
    func untrustedFutureReversed() {
        let beyondCeiling = TimeInterval(SleepLimits.maxDurationSeconds + SleepLimits.durationSlackSeconds + 1)
        #expect(Reconciliation.decide(state: state(deadlineOffset: beyondCeiling), sleepDisabled: true, now: now) == .reverseAndClear)
        #expect(Reconciliation.decide(state: state(deadlineOffset: beyondCeiling), sleepDisabled: false, now: now) == .reverseAndClear)
    }
}
