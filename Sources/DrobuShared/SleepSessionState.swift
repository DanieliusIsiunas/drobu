import Foundation

/// Tunable limits for closed-lid sessions. Constants live here (DrobuShared) so
/// the daemon (enforcement) and the tests reference one source.
///
/// Review note M4 / Open Question 4: the duty-cycle ceiling is defense-in-depth
/// and deliberately tunable — revisit `dutyCycleCapSeconds` / window against
/// real heavy-user telemetry before treating these values as load-bearing.
public enum SleepLimits {
    /// The durations the `/sleep` UI offers (seconds). A request must match one
    /// of these within `durationSlackSeconds`.
    public static let allowedDurationsSeconds: [Int] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]

    /// Largest single session a caller may request.
    public static let maxDurationSeconds: Int = 4 * 60 * 60

    /// Slack on bounds checks (clock skew, rounding). Also bounds the
    /// trustworthy-deadline ceiling on the persisted state file.
    public static let durationSlackSeconds: Int = 60

    /// Cumulative active seconds permitted within `dutyCycleWindowSeconds`.
    public static let dutyCycleCapSeconds: TimeInterval = 8 * 60 * 60

    /// Rolling window the duty-cycle cap applies over.
    public static let dutyCycleWindowSeconds: TimeInterval = 24 * 60 * 60

    /// Leaky-bucket drain rate (active-seconds per wall-clock-second). At
    /// `cap/window` the accumulator fully drains over one idle window.
    static var dutyCycleLeakRate: TimeInterval { dutyCycleCapSeconds / dutyCycleWindowSeconds }
}

/// Persisted, root-owned session state — the daemon's single source of truth
/// for when the current session ends and how much active time has accrued in
/// the rolling duty-cycle window. All time math takes an injected `now` so the
/// tests are wall-clock-free (the `LicenseManager` `now:`-closure idiom, not the
/// `CaffeinateService` `duration: 0` hack).
public struct SleepSessionState: Codable, Equatable, Sendable {
    /// Absolute session end. The watchdog and every reconciliation cell key off
    /// this — never off the nominal duration.
    public var deadline: Date

    /// When the current active session began.
    public var startedAt: Date

    /// Leaky-bucket accumulator: active seconds consumed in the rolling window,
    /// as of `accumulatorUpdatedAt`. Decayed by elapsed wall-clock on read.
    ///
    /// Deviation from R8's "reset on clean stop": the accumulator is NOT reset
    /// on stop. Resetting on stop would make the ceiling trivially bypassable
    /// by stop+restart, defeating its only purpose (bounding a looping caller).
    /// Early stops merely over-count, which the decay self-heals.
    public var accumulatedActiveSeconds: TimeInterval
    public var accumulatorUpdatedAt: Date

    public init(deadline: Date, startedAt: Date, accumulatedActiveSeconds: TimeInterval, accumulatorUpdatedAt: Date) {
        self.deadline = deadline
        self.startedAt = startedAt
        self.accumulatedActiveSeconds = accumulatedActiveSeconds
        self.accumulatorUpdatedAt = accumulatorUpdatedAt
    }

    /// Seconds until the deadline, floored at 0.
    public func remaining(now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    public func isExpired(now: Date) -> Bool {
        remaining(now: now) <= 0
    }

    /// A persisted deadline beyond `now + maxDuration + slack` cannot have been
    /// produced by a legitimate `enable` — treat as tampered/untrusted. (The
    /// daemon also verifies file owner/mode on read; that hazard is daemon-side
    /// and not unit-testable, but this ceiling is.)
    public func isDeadlineTrustworthy(now: Date) -> Bool {
        let ceiling = now.addingTimeInterval(TimeInterval(SleepLimits.maxDurationSeconds + SleepLimits.durationSlackSeconds))
        return deadline <= ceiling
    }

    /// The duty-cycle accumulator decayed forward to `now` (leaky bucket).
    public func decayedAccumulatedSeconds(now: Date) -> TimeInterval {
        let elapsed = max(0, now.timeIntervalSince(accumulatorUpdatedAt))
        return max(0, accumulatedActiveSeconds - elapsed * SleepLimits.dutyCycleLeakRate)
    }
}

/// JSON codec for the persisted state file. Default `Date` coding (Double
/// seconds since reference date) round-trips exactly — chosen over `.iso8601`,
/// which loses sub-second precision and would make round-trip assertions
/// flaky. Sorted keys keep the on-disk bytes deterministic.
public enum SleepSessionStateCodec {
    public static func encode(_ state: SleepSessionState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    public static func decode(_ data: Data) throws -> SleepSessionState {
        try JSONDecoder().decode(SleepSessionState.self, from: data)
    }
}
