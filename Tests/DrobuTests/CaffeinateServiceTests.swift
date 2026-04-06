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
}
