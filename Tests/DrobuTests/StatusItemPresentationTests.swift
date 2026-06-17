import Testing
import Foundation
@testable import DrobuCore

@Suite("StatusItemPresentation")
struct StatusItemPresentationTests {

    // MARK: - menuItemTitle

    @Test(
        "menuItemTitle formats the version, tolerating v-prefix and empty input",
        arguments: [
            ("1.9.1", "Update available — v1.9.1"),
            ("v1.9.1", "Update available — v1.9.1"),   // no double-prefix
            ("V2.0", "Update available — v2.0"),
            ("  1.10.0  ", "Update available — v1.10.0"), // trims whitespace
            ("", "Update available"),                    // no bare "v"
            ("   ", "Update available"),
            ("v", "Update available"),                   // prefix-only -> no bare "v"
        ]
    )
    func menuItemTitle(version: String, expected: String) {
        #expect(StatusItemPresentation.menuItemTitle(version: version) == expected)
    }

    // MARK: - statusIconIndicators (coexistence matrix)
    // Full sleep×update matrix below; the (mode, true) rows already assert the
    // arrow shows alongside every sleep dot, so no separate coexistence test.

    @Test(
        "statusIconIndicators: sleep dot and update arrow are independent",
        arguments: [
            // (sleepMode, updatePending) -> (sleepDot, showsUpdateArrow)
            (SleepMode.none, false, StatusIconIndicators(sleepDot: nil, showsUpdateArrow: false)),
            (SleepMode.keepAwake, false, StatusIconIndicators(sleepDot: .green, showsUpdateArrow: false)),
            (SleepMode.closedLid, false, StatusIconIndicators(sleepDot: .orange, showsUpdateArrow: false)),
            (SleepMode.none, true, StatusIconIndicators(sleepDot: nil, showsUpdateArrow: true)),
            (SleepMode.keepAwake, true, StatusIconIndicators(sleepDot: .green, showsUpdateArrow: true)),
            (SleepMode.closedLid, true, StatusIconIndicators(sleepDot: .orange, showsUpdateArrow: true)),
        ]
    )
    func statusIconIndicators(
        mode: SleepMode,
        pending: Bool,
        expected: StatusIconIndicators
    ) {
        #expect(
            StatusItemPresentation.statusIconIndicators(sleepMode: mode, updatePending: pending) == expected
        )
    }

    // MARK: - statusButtonAccessibilityLabel

    @Test("accessibility label reflects pending state")
    func accessibilityLabel() {
        #expect(StatusItemPresentation.statusButtonAccessibilityLabel(updatePending: true) == "Drobu — update available")
        #expect(StatusItemPresentation.statusButtonAccessibilityLabel(updatePending: false) == "Drobu")
    }
}
