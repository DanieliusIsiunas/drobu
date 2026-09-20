import Testing
import Foundation
import IOKit.pwr_mgt
@testable import DrobuCore

/// Records assertion lifecycle so the service's state machine can be tested
/// without taking real power assertions (which would genuinely keep the test
/// machine awake).
final class FakePowerAssertion: PowerAssertionHolding {
    private(set) var isHeld = false
    private(set) var holdCount = 0
    private(set) var releaseCount = 0
    private(set) var lastDuration: TimeInterval?
    private(set) var lastReason: String?
    /// Flip to false to simulate the OS refusing the assertion.
    var shouldSucceed = true

    func hold(duration: TimeInterval, reason: String) -> Bool {
        holdCount += 1
        lastDuration = duration
        lastReason = reason
        guard shouldSucceed else {
            isHeld = false
            return false
        }
        isHeld = true
        return true
    }

    func release() {
        releaseCount += 1
        isHeld = false
    }
}

@Suite("CaffeinateService")
@MainActor
struct CaffeinateServiceTests {

    /// Builds a service wired to a fake so no real power assertion is taken.
    private func makeService() -> (CaffeinateService, FakePowerAssertion) {
        let fake = FakePowerAssertion()
        return (CaffeinateService(assertion: fake), fake)
    }

    @Test func startSetsIsActiveToTrue() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.start(duration: 60)
        #expect(service.isActive)
        #expect(service.remainingTime != nil)
    }

    @Test func stopSetsIsActiveToFalse() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.start(duration: 60)
        service.stop()
        #expect(!service.isActive)
        #expect(service.remainingTime == nil)
    }

    @Test func startWhileActiveTerminatesOldAndStartsNew() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.start(duration: 60)
        let firstRemaining = service.remainingTime

        service.start(duration: 120)
        #expect(service.isActive)
        // New session has longer remaining time than old
        #expect(service.remainingTime! > firstRemaining!)
    }

    @Test func isActiveReturnsFalseWhenDurationElapsed() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        // Start with a tiny duration that has already elapsed by wall-clock math
        service.start(duration: 0)
        // isActive checks remainingTime <= 0 via wall-clock, not assertion state
        #expect(!service.isActive)
    }

    // Regression: the menu-bar "keep awake" dot is driven by `state` transitions
    // (onStateChange). Nothing else flips `state` back to .idle when a session
    // simply runs out, so without the deadline timer the dot persisted after the
    // session expired. reconcileExpiry (fired by that timer) closes the gap.
    @Test func reconcileExpiryEndsExpiredSessionSoStateMatchesIsActive() {
        let (service, _) = makeService()
        defer { service.cleanup() }
        var fired: [CaffeinateService.State] = []
        service.onStateChange = { fired.append($0) }

        // duration 0 → already expired by wall-clock, but `state` is still .active.
        // This is the exact bug shape — isActive=false while the badge (driven off
        // state) stays lit.
        service.start(duration: 0)
        #expect(!service.isActive)
        #expect(service.state != .idle)

        service.reconcileExpiry()           // what the deadline timer calls
        #expect(service.state == .idle)     // state now agrees with isActive
        // Exactly one idle transition — no double-fire of onStateChange (which
        // would redundantly refresh the badge).
        #expect(fired.filter { $0 == .idle }.count == 1)
    }

    @Test func reconcileExpiryIsNoOpWhileStillActive() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.start(duration: 600)
        service.reconcileExpiry()
        #expect(service.isActive)
        #expect(service.state != .idle)
    }

    @Test func reconcileExpiryIsNoOpWhenIdle() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.reconcileExpiry()
        #expect(service.state == .idle)
    }

    @Test func onStateChangeFiresOnStart() {
        let (service, _) = makeService()
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
        let (service, _) = makeService()
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
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.start(duration: 600)
        service.extend(by: 3600)
        #expect(service.isActive)
        // Lower-bound assertion only — wall clock elapses during the test.
        #expect(service.remainingTime! > 4100)
    }

    @Test func extendWhenIdleIsNoOp() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        service.extend(by: 3600)
        #expect(!service.isActive)
        #expect(service.state == .idle)
    }

    @Test func extendAfterExpiryIsNoOp() {
        let (service, _) = makeService()
        defer { service.cleanup() }

        // Duration 0 has already elapsed by wall-clock math → isActive false
        service.start(duration: 0)
        service.extend(by: 3600)
        #expect(!service.isActive)
    }

    @Test func onStateChangeFiresOnExtend() {
        let (service, _) = makeService()
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

    // MARK: - Power assertion lifecycle
    //
    // The whole point of the session is that something holds the Mac awake.
    // These pin the assertion to the session so a future refactor cannot leave
    // the state machine intact while silently holding nothing.

    @Test func startHoldsAssertionForTheSessionDuration() {
        let (service, fake) = makeService()
        defer { service.cleanup() }

        service.start(duration: 600)
        #expect(fake.isHeld)
        #expect(fake.holdCount == 1)
        #expect(fake.lastDuration == 600)
        #expect(fake.lastReason == "Drobu Keep Awake")
    }

    @Test func stopReleasesAssertion() {
        let (service, fake) = makeService()
        defer { service.cleanup() }

        service.start(duration: 600)
        service.stop()
        #expect(!fake.isHeld)
    }

    @Test func cleanupReleasesAssertion() {
        let (service, fake) = makeService()

        service.start(duration: 600)
        service.cleanup()
        #expect(!fake.isHeld)
    }

    @Test func reconcileExpiryReleasesAssertion() {
        let (service, fake) = makeService()
        defer { service.cleanup() }

        service.start(duration: 0)
        service.reconcileExpiry()
        #expect(!fake.isHeld)
    }

    /// A zero/negative duration is already expired, so there is nothing to keep
    /// awake *for* — taking an assertion would hold the Mac awake with a kernel
    /// timeout of 0 (which means "never time out").
    @Test func zeroDurationHoldsNoAssertion() {
        let (service, fake) = makeService()
        defer { service.cleanup() }

        service.start(duration: 0)
        #expect(fake.holdCount == 0)
        #expect(!fake.isHeld)
    }

    /// If the OS refuses the assertion, nothing is holding the Mac awake — so the
    /// service must NOT report an active session (which would light the menu-bar
    /// badge and promise a keep-awake that isn't happening).
    @Test func refusedAssertionDoesNotEnterActiveState() {
        let (service, fake) = makeService()
        defer { service.cleanup() }
        fake.shouldSucceed = false

        service.start(duration: 600)
        #expect(!service.isActive)
        #expect(service.state == .idle)
    }

    /// A refusal while a session is already running must end that session exactly
    /// once — the old assertions are already released by then, so staying `.active`
    /// would strand a lit badge over nothing.
    @Test func refusedAssertionEndsAnAlreadyActiveSession() {
        let (service, fake) = makeService()
        defer { service.cleanup() }

        service.start(duration: 600)
        var fired: [CaffeinateService.State] = []
        service.onStateChange = { fired.append($0) }

        fake.shouldSucceed = false
        service.start(duration: 600)

        #expect(service.state == .idle)
        #expect(fired.filter { $0 == .idle }.count == 1)
    }

    @Test func extendReplacesTheHeldAssertion() {
        let (service, fake) = makeService()
        defer { service.cleanup() }

        service.start(duration: 600)
        service.extend(by: 3600)
        #expect(fake.holdCount == 2)
        #expect(fake.isHeld)
        #expect(fake.lastDuration! > 4100)
    }

    /// Exercises the real IOKit implementation (not the fake) so a change to the
    /// assertion types/properties that the kernel rejects fails here rather than
    /// in the field. Harmless: the assertions are released before the test ends.
    @Test func realIOPMAssertionHoldsAndReleases() {
        let real = IOPMPowerAssertion()
        defer { real.release() }

        #expect(!real.isHeld)
        #expect(real.hold(duration: 30, reason: "Drobu test"))
        #expect(real.isHeld)

        real.release()
        #expect(!real.isHeld)

        // Release is idempotent — a second call must not crash or flip state.
        real.release()
        #expect(!real.isHeld)
    }

    @Test func realIOPMAssertionRefusesNonPositiveDuration() {
        let real = IOPMPowerAssertion()
        defer { real.release() }

        #expect(!real.hold(duration: 0, reason: "Drobu test"))
        #expect(!real.isHeld)
    }

    /// Regression: a session allowed to run to its deadline is released by powerd
    /// at the kernel timeout, so the app's own release lands on an ID the kernel
    /// already dropped and gets `kIOReturnBadArgument` back. Logging that as an
    /// error put two ERROR lines in `app.log` for every *healthy* session while
    /// early-stopped sessions stayed silent — inverted signal in the file this
    /// project's runbook says to read first. Verified live: post-timeout release
    /// returns 0xE00002C2.
    @Test func alreadyReleasedCodesAreNotTreatedAsFailures() {
        #expect(IOPMPowerAssertion.isAlreadyReleased(kIOReturnBadArgument))
        #expect(IOPMPowerAssertion.isAlreadyReleased(kIOReturnNotFound))
        // A genuine failure must still be reported.
        #expect(!IOPMPowerAssertion.isAlreadyReleased(kIOReturnNoMemory))
        #expect(!IOPMPowerAssertion.isAlreadyReleased(kIOReturnNotPermitted))
    }
}
