import Testing
import Foundation
@testable import DrobuCore

@Suite("SleepCommand formatting")
@MainActor
struct SleepCommandFormattingTests {

    @Test(
        "formatRemaining floors to whole minutes and includes ' left'",
        arguments: [
            (0.0, "< 1 min left"),
            (59.0, "< 1 min left"),
            (60.0, "1 min left"),
            (90.0, "1 min left"),
            (1380.0, "23 min left"),
            (3600.0, "1 hr left"),
            (3900.0, "1 hr 5 min left"),
            (7200.0, "2 hr left"),
            (7260.0, "2 hr 1 min left"),
        ]
    )
    func formatRemaining(seconds: Double, expected: String) {
        #expect(SleepCommand.formatRemaining(seconds) == expected)
    }
}
