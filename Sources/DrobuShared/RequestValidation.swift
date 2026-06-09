import Foundation

/// Why a `enable` request was refused. Maps onto `DaemonEnableResult`.
public enum SleepRequestRejection: Equatable, Sendable {
    case durationNotAllowed
    case dutyCycleExceeded

    public var enableResult: DaemonEnableResult {
        switch self {
        case .durationNotAllowed: return .durationNotAllowed
        case .dutyCycleExceeded: return .dutyCycleExceeded
        }
    }
}

/// The daemon's own request control (R8). Independent of XPC peer validation —
/// it must hold even if peer validation were bypassed, because the blast radius
/// of `enable` is persistent sleep denial (battery drain / thermal in a bagged
/// laptop), not mere annoyance.
public enum RequestValidation {
    /// A requested duration is allowed iff it is positive, within
    /// `maxDuration + slack`, and within `slack` of one of the offered durations.
    public static func isDurationAllowed(_ durationSeconds: Int) -> Bool {
        guard durationSeconds > 0 else { return false }
        guard durationSeconds <= SleepLimits.maxDurationSeconds + SleepLimits.durationSlackSeconds else { return false }
        return SleepLimits.allowedDurationsSeconds.contains { allowed in
            abs(durationSeconds - allowed) <= SleepLimits.durationSlackSeconds
        }
    }

    /// Validate a request against bounds + the rolling duty-cycle ceiling.
    /// Returns `nil` when accepted, else the rejection reason. Pure; inject
    /// `now`. `priorState` is the persisted state before this request (nil when
    /// idle); its accumulator is decayed to `now` before the check.
    ///
    /// Each `enable` (including an idempotent re-arm) counts its requested
    /// duration against the budget — re-arming IS the abuse vector being
    /// bounded, so counting every arm is intentional.
    public static func validate(durationSeconds: Int, now: Date, priorState: SleepSessionState?) -> SleepRequestRejection? {
        guard isDurationAllowed(durationSeconds) else { return .durationNotAllowed }
        let priorDecayed = priorState?.decayedAccumulatedSeconds(now: now) ?? 0
        if priorDecayed + TimeInterval(durationSeconds) > SleepLimits.dutyCycleCapSeconds {
            return .dutyCycleExceeded
        }
        return nil
    }

    /// The accumulator value to persist after a granted request — prior decayed
    /// total plus the newly committed duration.
    public static func accumulatorAfterGrant(durationSeconds: Int, now: Date, priorState: SleepSessionState?) -> TimeInterval {
        let priorDecayed = priorState?.decayedAccumulatedSeconds(now: now) ?? 0
        return priorDecayed + TimeInterval(durationSeconds)
    }
}
