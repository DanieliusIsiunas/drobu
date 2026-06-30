import AppKit

/// The modifier flags relevant to Shift-tap detection — the four a user can
/// chord with. Caps Lock / Fn / numericPad bits are masked out before the
/// decision runs, so device-dependent noise never reaches `shiftTapDecision`.
let shiftTapRelevantModifiers: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

/// Pure decision for the bare-Shift-tap gesture that toggles the large preview.
///
/// Arms only on a **rising edge to lone-Shift**: the previously-observed modifier
/// state did NOT contain Shift, and the new state is exactly `[.shift]`.
/// `FloatingPanel` seeds `previous` from the modifier state captured at show-time
/// (the invoking chord — e.g. `⇧⌘C` — is still physically held), so the chord's
/// Shift counts as already-down and its release tail (`⇧⌘`→`⇧`→`∅`, or
/// `⇧⌘`→`⌘`→`∅`) never produces a Shift rising edge → never arms. This is
/// independent of how long the chord is held and of which modifier lifts first —
/// the two properties a time-based grace window could not guarantee.
///
/// A *deliberate* tap presses Shift up from a no-Shift state → a genuine rising
/// edge → arms; the tap fires when all modifiers release while armed. A redundant
/// non-rising lone-Shift event preserves the standing armed state so a duplicate
/// `flagsChanged` cannot silently drop a deliberate arm.
///
/// `previous` and `current` MUST already be masked to `shiftTapRelevantModifiers`.
/// There is intentionally no time/clock input — arming is purely edge-based.
func shiftTapDecision(previous: NSEvent.ModifierFlags,
                      current: NSEvent.ModifierFlags,
                      armed: Bool) -> (armed: Bool, fireTap: Bool) {
    if current == [.shift] {
        // Lone Shift held. Arm only on a rising edge (Shift was not down before);
        // a non-rising repeat preserves the existing armed state.
        if !previous.contains(.shift) {
            return (armed: true, fireTap: false)
        }
        return (armed: armed, fireTap: false)
    }
    if current.isEmpty {
        // All modifiers released. Fire iff a valid lone-Shift arm is standing.
        return (armed: false, fireTap: armed)
    }
    // A non-Shift modifier is present (a chord forming or held) — never arm.
    return (armed: false, fireTap: false)
}
