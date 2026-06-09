import Foundation
import Testing
@testable import DrobuShared

@Suite("pmset SleepDisabled parsing")
struct PmsetParsingTests {

    @Test("reads SleepDisabled 1 as true")
    func disabledTrue() {
        #expect(parseSleepDisabled(fromPmsetG: "SleepDisabled          1") == true)
    }

    @Test("reads SleepDisabled 0 as false")
    func disabledFalse() {
        #expect(parseSleepDisabled(fromPmsetG: "SleepDisabled          0") == false)
    }

    @Test("M1 regression: standby 1 does NOT make SleepDisabled 0 read as true")
    func standbyOneDoesNotLeak() {
        let output = """
        System-wide power settings:
         SleepDisabled          0
        Currently in use:
         standby              1
         hibernatemode        3
         displaysleep         10
        """
        #expect(parseSleepDisabled(fromPmsetG: output) == false)
    }

    @Test("finds SleepDisabled 1 among many lines")
    func disabledAmongLines() {
        let output = """
        Currently in use:
         standby              0
         SleepDisabled        1
         hibernatemode        0
        """
        #expect(parseSleepDisabled(fromPmsetG: output) == true)
    }

    @Test("no SleepDisabled line → false")
    func absentIsFalse() {
        let output = """
         standby              1
         displaysleep         10
        """
        #expect(parseSleepDisabled(fromPmsetG: output) == false)
    }

    @Test("empty output → false")
    func emptyIsFalse() {
        #expect(parseSleepDisabled(fromPmsetG: "") == false)
    }
}
