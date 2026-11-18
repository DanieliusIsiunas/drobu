import Foundation
import Testing
@testable import DrobuCore
@testable import DrobuShared

@Suite("SleepCommand durations")
@MainActor
struct SleepCommandDurationTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("every offered duration is accepted by the Closed Lid daemon")
    func offeredDurationsMatchDaemonAllowlist() {
        // A UI duration the daemon doesn't allow fails Closed Lid as
        // `durationNotAllowed` — only at runtime, behind the privileged helper.
        for item in SleepCommand.durations {
            #expect(RequestValidation.isDurationAllowed(Int(item.seconds)), "\(item.label) not allowed by daemon")
        }
        #expect(SleepCommand.durations.map { Int($0.seconds) } == SleepLimits.allowedDurationsSeconds)
    }

    @Test("8 hours is offered as the longest option")
    func eightHoursOffered() {
        let last = SleepCommand.durations.last
        #expect(last?.id == "8h")
        #expect(last?.label == "8 hours")
        #expect(last?.seconds == TimeInterval(8 * 3600))
        #expect(SleepLimits.maxDurationSeconds == 8 * 3600)
    }

    @Test("an 8h Closed Lid session leaves duty-cycle room for more use the same day")
    func eightHourSessionLeavesBudget() {
        #expect(RequestValidation.validate(durationSeconds: 8 * 3600, now: now, priorState: nil) == nil)
        // Right after a full 8h session (no decay yet), a 4h session still fits.
        let afterOvernight = SleepSessionState(
            deadline: now, startedAt: now.addingTimeInterval(-8 * 3600),
            accumulatedActiveSeconds: 8 * 3600, accumulatorUpdatedAt: now
        )
        #expect(RequestValidation.validate(durationSeconds: 4 * 3600, now: now, priorState: afterOvernight) == nil)
        // Two back-to-back 8h sessions exhaust the 16h cap; a third is refused.
        let afterTwo = SleepSessionState(
            deadline: now, startedAt: now,
            accumulatedActiveSeconds: 16 * 3600, accumulatorUpdatedAt: now
        )
        #expect(RequestValidation.validate(durationSeconds: 15 * 60, now: now, priorState: afterTwo) == .dutyCycleExceeded)
    }
}
