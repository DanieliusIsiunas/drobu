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

    @Test("10 hours is offered as the longest option")
    func tenHoursOffered() {
        let last = SleepCommand.durations.last
        #expect(last?.id == "10h")
        #expect(last?.label == "10 hours")
        #expect(last?.seconds == TimeInterval(10 * 3600))
        #expect(SleepLimits.maxDurationSeconds == 10 * 3600)
    }

    @Test("a 10h Closed Lid session leaves duty-cycle room for more use the same day")
    func tenHourSessionLeavesBudget() {
        #expect(RequestValidation.validate(durationSeconds: 10 * 3600, now: now, priorState: nil) == nil)
        // Right after a full 10h session (no decay yet), a 4h session still fits.
        let afterOvernight = SleepSessionState(
            deadline: now, startedAt: now.addingTimeInterval(-10 * 3600),
            accumulatedActiveSeconds: 10 * 3600, accumulatorUpdatedAt: now
        )
        #expect(RequestValidation.validate(durationSeconds: 4 * 3600, now: now, priorState: afterOvernight) == nil)
        // Two back-to-back 10h sessions exhaust the 20h cap; a third is refused.
        let afterTwo = SleepSessionState(
            deadline: now, startedAt: now,
            accumulatedActiveSeconds: 20 * 3600, accumulatorUpdatedAt: now
        )
        #expect(RequestValidation.validate(durationSeconds: 15 * 60, now: now, priorState: afterTwo) == .dutyCycleExceeded)
    }
}
