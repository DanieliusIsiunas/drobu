import AppKit
import Testing
@testable import DrobuCore

@Suite("ShiftTapDetector")
struct ShiftTapDetectorTests {

    // R5 — a deliberate tap (Shift pressed up from no-Shift, then released) fires.
    @Test("deliberate tap: release while armed fires")
    func releaseWhileArmedFires() {
        let d = shiftTapDecision(previous: [.shift], current: [], armed: true)
        #expect(d.armed == false)
        #expect(d.fireTap == true)
    }

    @Test("rising-edge lone Shift arms")
    func risingEdgeArms() {
        let d = shiftTapDecision(previous: [], current: [.shift], armed: false)
        #expect(d.armed == true)
        #expect(d.fireTap == false)
    }

    // R3 — the headline case: ⇧⌘C release, Cmd lifts first leaving lone Shift,
    // but Shift was already down (seeded from show-time) so it is NOT a rising edge.
    @Test("chord-release tail, Cmd lifts first, never arms")
    func chordTailCmdFirst() {
        let d = shiftTapDecision(previous: [.shift, .command], current: [.shift], armed: false)
        #expect(d.armed == false)
        #expect(d.fireTap == false)
    }

    // R3 — full release after the unarmed chord tail does not fire.
    @Test("chord-release tail then full release: no fire")
    func chordTailFullRelease() {
        let d = shiftTapDecision(previous: [.shift], current: [], armed: false)
        #expect(d.armed == false)
        #expect(d.fireTap == false)
    }

    // R3 — release-order independence: Shift lifts first leaving lone Cmd.
    @Test("chord-release tail, Shift lifts first, never arms")
    func chordTailShiftFirst() {
        let d = shiftTapDecision(previous: [.shift, .command], current: [.command], armed: false)
        #expect(d.armed == false)
        #expect(d.fireTap == false)
    }

    @Test("simultaneous chord rising edge never arms")
    func simultaneousChord() {
        let d = shiftTapDecision(previous: [], current: [.shift, .command], armed: false)
        #expect(d.armed == false)
        #expect(d.fireTap == false)
    }

    // R4 — after a multi-select, the keyDown disarm already cleared `armed`,
    // so releasing Shift does not fire.
    @Test("post-multi-select release with armed cleared: no fire")
    func postMultiSelectRelease() {
        let d = shiftTapDecision(previous: [.shift], current: [], armed: false)
        #expect(d.fireTap == false)
    }

    // R5 guard — a duplicate lone-Shift event must not drop a standing arm.
    @Test("redundant non-rising lone Shift preserves arm")
    func redundantLoneShiftPreservesArm() {
        let d = shiftTapDecision(previous: [.shift], current: [.shift], armed: true)
        #expect(d.armed == true)
        #expect(d.fireTap == false)
    }
}
