import AppKit
import Testing
@testable import DrobuCore

/// Covers `isShiftClickGesture` (`Sources/DrobuCore/Views/RowDragSourceView.swift`) —
/// the pure half of the row press pipeline. Kept out of `ShiftTapDetectorTests`
/// because that suite's subject is `shiftTapDecision`'s (previous, current, armed)
/// triple; this function has a different source file, a different contract (it
/// masks its own input), and a different consumer (the row NSView, not the panel).
/// The NSView lifecycle and the panel's event monitors around it are out of test
/// scope per `CLAUDE.md` ("What NOT to test: SwiftUI views … AppKit UI wiring").
@Suite("RowGestureClassification")
struct RowGestureClassificationTests {

    // R1/KTD6 — the gesture: lone Shift held at mouseDown toggles the row.
    @Test("bare Shift is the selection gesture")
    func bareShiftIsGesture() {
        #expect(isShiftClickGesture([.shift]) == true)
    }

    // R11-adjacent — any chord stays "plain" so it can never be mistaken for a
    // toggle. Exactly-equal (not `.contains`) is what buys this.
    @Test("Shift chorded with another modifier is not the gesture",
          arguments: [
            NSEvent.ModifierFlags([.shift, .command]),
            NSEvent.ModifierFlags([.shift, .option]),
            NSEvent.ModifierFlags([.shift, .control]),
            NSEvent.ModifierFlags([.shift, .command, .option]),
          ])
    func shiftChordsAreNotGesture(_ flags: NSEvent.ModifierFlags) {
        #expect(isShiftClickGesture(flags) == false)
    }

    // A plain click and a non-Shift chord both stay on the paste path.
    @Test("no-Shift states are not the gesture",
          arguments: [
            NSEvent.ModifierFlags([]),
            NSEvent.ModifierFlags([.command]),
            NSEvent.ModifierFlags([.option]),
            NSEvent.ModifierFlags([.control]),
          ])
    func nonShiftStatesAreNotGesture(_ flags: NSEvent.ModifierFlags) {
        #expect(isShiftClickGesture(flags) == false)
    }

    // The whole point of masking internally: real `NSEvent.modifierFlags` carry
    // device noise (Caps Lock, Fn, numericPad — the same bits that make
    // `modifiers.isEmpty` always false for arrow keys, see
    // `.claude/rules/swiftui-keypress-gotchas.md`). An unmasked `== [.shift]`
    // comparison would silently drop the gesture whenever any of them is set.
    @Test("device noise on top of Shift still classifies as the gesture",
          arguments: [
            NSEvent.ModifierFlags([.shift, .capsLock]),
            NSEvent.ModifierFlags([.shift, .function]),
            NSEvent.ModifierFlags([.shift, .numericPad]),
            NSEvent.ModifierFlags([.shift, .capsLock, .function, .numericPad]),
          ])
    func deviceNoiseWithShiftIsGesture(_ flags: NSEvent.ModifierFlags) {
        #expect(isShiftClickGesture(flags) == true)
    }

    // Noise alone must not become a gesture — masking removes the noise, it does
    // not treat it as Shift.
    @Test("device noise without Shift is not the gesture")
    func deviceNoiseWithoutShiftIsNotGesture() {
        #expect(isShiftClickGesture([.capsLock, .function, .numericPad]) == false)
        // Noise plus a real chord is still plain.
        #expect(isShiftClickGesture([.capsLock, .shift, .command]) == false)
    }
}
