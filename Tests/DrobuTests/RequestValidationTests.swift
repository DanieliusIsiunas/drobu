import Foundation
import Testing
@testable import DrobuShared

@Suite("RequestValidation")
struct RequestValidationTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("each offered duration is allowed", arguments: SleepLimits.allowedDurationsSeconds)
    func allowedDurations(_ seconds: Int) {
        #expect(RequestValidation.isDurationAllowed(seconds))
    }

    @Test("durations within slack of an offered value are allowed")
    func slackedDurations() {
        #expect(RequestValidation.isDurationAllowed(900 + 30))   // ~15m
        #expect(RequestValidation.isDurationAllowed(3600 - 60))  // ~1h, at slack edge
        #expect(RequestValidation.isDurationAllowed(SleepLimits.maxDurationSeconds + SleepLimits.durationSlackSeconds))
    }

    @Test("the lower-slack boundary of the minimum duration is exact")
    func lowerSlackBoundary() {
        // 900 (15m) is the smallest offered duration; slack is 60.
        #expect(RequestValidation.isDurationAllowed(900 - 60))       // 840: exactly at slack -> allowed
        #expect(RequestValidation.isDurationAllowed(900 - 61) == false) // 839: one past slack -> rejected
    }

    @Test("out-of-set, zero, negative, and over-max durations are rejected")
    func rejectedDurations() {
        #expect(RequestValidation.isDurationAllowed(0) == false)
        #expect(RequestValidation.isDurationAllowed(-300) == false)
        #expect(RequestValidation.isDurationAllowed(1000) == false)  // nearest 900, diff 100 > 60
        #expect(RequestValidation.isDurationAllowed(SleepLimits.maxDurationSeconds + SleepLimits.durationSlackSeconds + 1) == false)
        #expect(RequestValidation.isDurationAllowed(10 * 3600) == false)
    }

    @Test("valid duration with no prior state is accepted")
    func acceptedFresh() {
        #expect(RequestValidation.validate(durationSeconds: 3600, now: now, priorState: nil) == nil)
        #expect(RequestValidation.validate(durationSeconds: SleepLimits.maxDurationSeconds, now: now, priorState: nil) == nil)
    }

    @Test("disallowed duration is rejected before the duty-cycle check")
    func rejectBadDuration() {
        #expect(RequestValidation.validate(durationSeconds: 7, now: now, priorState: nil) == .durationNotAllowed)
    }

    @Test("a request that would exceed the rolling duty-cycle cap is rejected")
    func rejectDutyCycle() {
        // Accumulator just under the cap, recorded now (no decay).
        let nearCap = SleepSessionState(
            deadline: now.addingTimeInterval(60),
            startedAt: now,
            accumulatedActiveSeconds: SleepLimits.dutyCycleCapSeconds - 100,
            accumulatorUpdatedAt: now
        )
        #expect(RequestValidation.validate(durationSeconds: 900, now: now, priorState: nearCap) == .dutyCycleExceeded)
    }

    @Test("duty-cycle decay lets a request through after enough idle time")
    func dutyCycleRecovers() {
        // Full cap consumed, but recorded a full window ago → fully decayed.
        let drained = SleepSessionState(
            deadline: now.addingTimeInterval(-1),
            startedAt: now.addingTimeInterval(-SleepLimits.dutyCycleWindowSeconds),
            accumulatedActiveSeconds: SleepLimits.dutyCycleCapSeconds,
            accumulatorUpdatedAt: now.addingTimeInterval(-SleepLimits.dutyCycleWindowSeconds)
        )
        #expect(RequestValidation.validate(durationSeconds: 3600, now: now, priorState: drained) == nil)
    }

    @Test("accumulator after a grant is prior decayed plus the new duration")
    func accumulatorGrant() {
        #expect(RequestValidation.accumulatorAfterGrant(durationSeconds: 3600, now: now, priorState: nil) == 3600)
        let prior = SleepSessionState(
            deadline: now, startedAt: now,
            accumulatedActiveSeconds: 1200, accumulatorUpdatedAt: now
        )
        #expect(RequestValidation.accumulatorAfterGrant(durationSeconds: 1800, now: now, priorState: prior) == 3000)
    }

    @Test("rejection reasons map to enable result codes")
    func rejectionMapping() {
        #expect(SleepRequestRejection.durationNotAllowed.enableResult == .durationNotAllowed)
        #expect(SleepRequestRejection.dutyCycleExceeded.enableResult == .dutyCycleExceeded)
    }
}
