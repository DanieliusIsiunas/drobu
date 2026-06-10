import Foundation
import Testing
@testable import DrobuShared

@Suite("SleepSessionState")
struct SleepSessionStateTests {
    // Fixed reference instant so every test is wall-clock-free.
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func state(deadlineOffset: TimeInterval = 3600,
                       accumulated: TimeInterval = 0,
                       accumulatorAgo: TimeInterval = 0) -> SleepSessionState {
        SleepSessionState(
            deadline: now.addingTimeInterval(deadlineOffset),
            startedAt: now,
            accumulatedActiveSeconds: accumulated,
            accumulatorUpdatedAt: now.addingTimeInterval(-accumulatorAgo)
        )
    }

    @Test("remaining floors at zero and reports future time")
    func remaining() {
        #expect(state(deadlineOffset: 3600).remaining(now: now) == 3600)
        #expect(state(deadlineOffset: -10).remaining(now: now) == 0)
        #expect(state(deadlineOffset: 1).remaining(now: now) == 1)
    }

    @Test("isExpired at the boundary and beyond")
    func expiry() {
        #expect(state(deadlineOffset: 1).isExpired(now: now) == false)
        #expect(state(deadlineOffset: 0).isExpired(now: now) == true)   // exactly expired
        #expect(state(deadlineOffset: -1).isExpired(now: now) == true)
    }

    @Test("deadline trust ceiling is now + maxDuration + slack")
    func deadlineTrust() {
        let ceiling = TimeInterval(SleepLimits.maxDurationSeconds + SleepLimits.durationSlackSeconds)
        #expect(state(deadlineOffset: 3600).isDeadlineTrustworthy(now: now) == true)
        #expect(state(deadlineOffset: ceiling).isDeadlineTrustworthy(now: now) == true)       // exactly at ceiling
        #expect(state(deadlineOffset: ceiling + 1).isDeadlineTrustworthy(now: now) == false)  // tampered future
        #expect(state(deadlineOffset: 5 * 3600).isDeadlineTrustworthy(now: now) == false)
    }

    @Test("duty-cycle accumulator decays by wall-clock at cap/window")
    func decay() {
        // 1h accumulated, recorded 1h ago. Leak rate = 8h/24h = 1/3.
        let decayed = state(accumulated: 3600, accumulatorAgo: 3600).decayedAccumulatedSeconds(now: now)
        #expect(abs(decayed - 2400) < 0.001)   // 3600 - 3600*(1/3)
        // Never goes negative.
        #expect(state(accumulated: 100, accumulatorAgo: 100_000).decayedAccumulatedSeconds(now: now) == 0)
        // No elapsed → no decay.
        #expect(state(accumulated: 5000, accumulatorAgo: 0).decayedAccumulatedSeconds(now: now) == 5000)
    }

    @Test("state codec round-trips exactly")
    func codecRoundTrip() throws {
        let original = state(deadlineOffset: 7200, accumulated: 1234.5, accumulatorAgo: 60)
        let data = try SleepSessionStateCodec.encode(original)
        let decoded = try SleepSessionStateCodec.decode(data)
        #expect(decoded == original)
    }

    @Test("corrupt state data fails to decode")
    func corruptDecodeThrows() {
        let garbage = Data("not json at all {{{".utf8)
        #expect(throws: (any Error).self) {
            _ = try SleepSessionStateCodec.decode(garbage)
        }
    }
}
