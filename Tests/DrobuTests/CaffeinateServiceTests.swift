import Testing
import Foundation
@testable import DrobuCore

@Suite("CaffeinateService")
@MainActor
struct CaffeinateServiceTests {

    @Test func startSetsIsActiveToTrue() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 60)
        #expect(service.isActive)
        #expect(service.remainingTime != nil)
    }

    @Test func stopSetsIsActiveToFalse() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 60)
        service.stop()
        #expect(!service.isActive)
        #expect(service.remainingTime == nil)
    }

    @Test func startWhileActiveTerminatesOldAndStartsNew() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 60)
        let firstRemaining = service.remainingTime

        service.start(duration: 120)
        #expect(service.isActive)
        // New session has longer remaining time than old
        #expect(service.remainingTime! > firstRemaining!)
    }

    @Test func isActiveReturnsFalseWhenDurationElapsed() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        // Start with a tiny duration that has already elapsed by wall-clock math
        service.start(duration: 0)
        // isActive checks remainingTime <= 0 via wall-clock, not process state
        #expect(!service.isActive)
    }

    // Regression: the menu-bar "keep awake" dot is driven by `state` transitions
    // (onStateChange). Before the deadline timer, `state` only flipped to .idle
    // when the OS caffeinate process terminated — which can lag the deadline — so
    // the dot persisted after the session expired. reconcileExpiry (fired by the
    // deadline timer) closes the gap.
    @Test func reconcileExpiryEndsExpiredSessionSoStateMatchesIsActive() {
        let service = CaffeinateService()
        defer { service.cleanup() }
        var fired: [CaffeinateService.State] = []
        service.onStateChange = { fired.append($0) }

        // duration 0 → already expired by wall-clock, but `state` is still .active:
        // the process-termination handler hops to the main actor, which can't run
        // during this synchronous test, so nothing has cleared state. This is the
        // exact bug — isActive=false while the badge (driven off state) stays.
        service.start(duration: 0)
        #expect(!service.isActive)
        #expect(service.state != .idle)

        service.reconcileExpiry()           // what the deadline timer calls
        #expect(service.state == .idle)     // state now agrees with isActive
        // Exactly one idle transition — no double-fire of onStateChange (which
        // would redundantly refresh the badge). stop() is the sole setter here.
        #expect(fired.filter { $0 == .idle }.count == 1)
    }

    @Test func reconcileExpiryIsNoOpWhileStillActive() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 600)
        service.reconcileExpiry()
        #expect(service.isActive)
        #expect(service.state != .idle)
    }

    @Test func reconcileExpiryIsNoOpWhenIdle() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.reconcileExpiry()
        #expect(service.state == .idle)
    }

    @Test func onStateChangeFiresOnStart() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        var firedStates: [CaffeinateService.State] = []
        service.onStateChange = { state in
            firedStates.append(state)
        }

        service.start(duration: 60)
        #expect(firedStates.count == 1)
        if case .active = firedStates.first {
            // correct
        } else {
            Issue.record("Expected .active state, got \(String(describing: firedStates.first))")
        }
    }

    @Test func onStateChangeFiresOnStop() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 60)

        var firedStates: [CaffeinateService.State] = []
        service.onStateChange = { state in
            firedStates.append(state)
        }

        service.stop()
        #expect(firedStates.count == 1)
        #expect(firedStates.first == .idle)
    }

    @Test func extendWhileActiveAddsToRemaining() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 600)
        service.extend(by: 3600)
        #expect(service.isActive)
        // Lower-bound assertion only — wall clock elapses during the test.
        #expect(service.remainingTime! > 4100)
    }

    @Test func extendWhenIdleIsNoOp() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.extend(by: 3600)
        #expect(!service.isActive)
        #expect(service.state == .idle)
    }

    @Test func extendAfterExpiryIsNoOp() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        // Duration 0 has already elapsed by wall-clock math → isActive false
        service.start(duration: 0)
        service.extend(by: 3600)
        #expect(!service.isActive)
    }

    @Test func onStateChangeFiresOnExtend() {
        let service = CaffeinateService()
        defer { service.cleanup() }

        service.start(duration: 60)

        var firedStates: [CaffeinateService.State] = []
        service.onStateChange = { state in
            firedStates.append(state)
        }

        service.extend(by: 3600)
        #expect(firedStates.count == 1)
        if case .active = firedStates.first {
            // correct
        } else {
            Issue.record("Expected .active state, got \(String(describing: firedStates.first))")
        }
    }
}
