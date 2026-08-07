import Testing
@testable import DrobuCore

/// Behavior pins for `PanelSelection` — the pure clipboard-panel selection model.
///
/// Every state in these tests is built by calling the real operations (the stored
/// properties are `private(set)`), so the setups double as sequence coverage: the
/// only way to reach a state here is the way the panel actually reaches it.
@Suite("PanelSelection")
struct PanelSelectionTests {

    /// A 5-row list. IDs are deliberately not equal to their indices so an
    /// index/ID mix-up in the implementation shows up as a wrong value, not a
    /// coincidentally-correct one (KTD4 — toggles are ID-keyed).
    private let ids: [Int64] = [10, 20, 30, 40, 50]

    /// An 8-row list for the shift-walk scenarios that need room to grow.
    private let ids8: [Int64] = [10, 20, 30, 40, 50, 60, 70, 80]

    // MARK: - Shift+Click toggling (R1)

    @Test("toggling two non-adjacent rows yields both in list order")
    func togglesNonAdjacentRowsInListOrder() {
        var s = PanelSelection()
        // Click order is bottom-then-top; the result must still be list order (R4).
        s.shiftClick(at: 4, ids: ids)
        s.shiftClick(at: 0, ids: ids)
        #expect(s.effectiveIDs(ids: ids) == [10, 50])
        #expect(s.selectedIndices(ids: ids) == [0, 4])
        #expect(s.hasMultiSelection(ids: ids))
    }

    /// AE6 / R13 — the cursor row can sit OUTSIDE the effective selection once it is
    /// toggled off while other rows stay selected. That is what lets the row drop its
    /// Return affordance (cursor row AND selected) while Return still pastes the rest.
    @Test("toggling a selected row off removes just that row, cursor included")
    func toggleOffRemovesOnlyThatRow() {
        var s = PanelSelection()
        s.shiftClick(at: 4, ids: ids)
        s.shiftClick(at: 0, ids: ids)
        s.shiftClick(at: 0, ids: ids)
        #expect(s.effectiveIDs(ids: ids) == [50])
        #expect(!s.hasMultiSelection(ids: ids))
        #expect(s.cursor == 0)
        #expect(!s.selectedIndices(ids: ids).contains(s.cursor))
    }

    /// KTD3's floor of one: with nothing toggled the cursor row stands in, so every
    /// downstream consumer (paste/delete/drag/preview) always sees at least one row.
    @Test("toggling the last remaining row off falls back to the cursor row")
    func emptyToggleSetFallsBackToCursor() {
        var s = PanelSelection()
        s.shiftClick(at: 2, ids: ids)
        s.shiftClick(at: 2, ids: ids)
        #expect(s.toggledIDs.isEmpty)
        #expect(s.effectiveIDs(ids: ids) == [30])
        #expect(s.selectedIndices(ids: ids) == [2])
        #expect(!s.hasMultiSelection(ids: ids))
    }

    /// KTD8 — both indices follow the click whether the toggle turned on OR off, so
    /// the preview shows the row just acted on and a following Shift+Arrow extends
    /// from it.
    @Test("Shift+Click moves anchor and cursor, on and off, leaving other rows alone")
    func shiftClickMovesBothIndices() {
        var s = PanelSelection()
        s.shiftClick(at: 1, ids: ids)
        s.shiftClick(at: 3, ids: ids)
        #expect(s.anchor == 3)
        #expect(s.cursor == 3)
        #expect(s.toggledIDs == [20, 40])

        s.shiftClick(at: 3, ids: ids)
        #expect(s.anchor == 3)
        #expect(s.cursor == 3)
        #expect(s.toggledIDs == [20])   // row 1's toggle is untouched
    }

    @Test("Shift+Click outside the list is a no-op")
    func shiftClickOutOfRangeIgnored() {
        var s = PanelSelection()
        s.shiftClick(at: 9, ids: ids)
        s.shiftClick(at: -1, ids: ids)
        #expect(s == PanelSelection())
    }

    // MARK: - Shift+Arrow range extension (R3)

    @Test("shift-walk grows and shrinks the live range")
    func shiftWalkGrowsAndShrinks() {
        var s = PanelSelection()
        s.shiftMove(by: 1, ids: ids)
        #expect(s.selectedIndices(ids: ids) == [0, 1])
        s.shiftMove(by: 1, ids: ids)
        #expect(s.selectedIndices(ids: ids) == [0, 1, 2])
        #expect(s.anchor == 0)
        #expect(s.cursor == 2)
        s.shiftMove(by: -1, ids: ids)
        #expect(s.selectedIndices(ids: ids) == [0, 1])
    }

    /// AE4 — a cherry-picked row survives an unrelated shift-walk in both directions.
    @Test("a cherry-picked row persists through range grow and shrink")
    func cherryPickPersistsThroughWalk() {
        var s = PanelSelection()
        s.shiftClick(at: 7, ids: ids8)   // cherry-pick the last row
        s.shiftClick(at: 1, ids: ids8)   // cherry-pick row 1; cursor+anchor land here
        s.shiftMove(by: 1, ids: ids8)
        #expect(s.selectedIndices(ids: ids8) == [1, 2, 7])
        s.shiftMove(by: 1, ids: ids8)
        #expect(s.selectedIndices(ids: ids8) == [1, 2, 3, 7])
        s.shiftMove(by: -1, ids: ids8)
        #expect(s.selectedIndices(ids: ids8) == [1, 2, 7])
    }

    /// PINNED QUIRK 1 (do not "fix"): the live range owns its whole span, so a
    /// cherry-picked row the range grew over is dropped when the range shrinks past
    /// it again. NSTableView behaves the same way.
    @Test("a toggled row absorbed by the range is dropped when the range shrinks past it")
    func absorbedRowIsDroppedOnShrink() {
        var s = PanelSelection()
        s.shiftClick(at: 3, ids: ids8)
        s.shiftClick(at: 0, ids: ids8)
        s.shiftMove(by: 1, ids: ids8)
        s.shiftMove(by: 1, ids: ids8)
        s.shiftMove(by: 1, ids: ids8)
        #expect(s.selectedIndices(ids: ids8) == [0, 1, 2, 3])   // row 3 absorbed
        s.shiftMove(by: -1, ids: ids8)
        #expect(s.selectedIndices(ids: ids8) == [0, 1, 2])       // and dropped
    }

    /// PINNED QUIRK 2 (do not "fix"): the sibling of quirk 1. Shift+Arrowing away
    /// from a row you just toggled OFF re-includes it, because the new range spans
    /// `anchor...cursor` and the anchor is that row.
    @Test("shift-move from a just-deselected row re-includes it in the new range")
    func rangeReincludesJustDeselectedAnchor() {
        var s = PanelSelection()
        s.shiftMove(by: 1, ids: ids)          // range 0...1
        s.shiftClick(at: 1, ids: ids)         // toggle row 1 back off; anchor = cursor = 1
        #expect(s.selectedIndices(ids: ids) == [0])
        s.shiftMove(by: 1, ids: ids)          // new range 1...2 sweeps row 1 back in
        #expect(s.selectedIndices(ids: ids) == [0, 1, 2])
    }

    @Test("shift-move clamps at both ends instead of wrapping")
    func shiftMoveClampsAtEnds() {
        var top = PanelSelection()
        top.shiftMove(by: -1, ids: ids)
        #expect(top.cursor == 0)
        #expect(top.selectedIndices(ids: ids) == [0])

        var bottom = PanelSelection()
        bottom.collapse(to: 4, ids: ids)
        bottom.shiftMove(by: 1, ids: ids)
        #expect(bottom.cursor == 4)
        #expect(bottom.selectedIndices(ids: ids) == [4])
    }

    // MARK: - Escape (R8)

    /// The degenerate state a Shift+Down / Shift+Up round-trip leaves: the toggled
    /// set holds exactly the cursor row's own ID, which renders identically to a
    /// bare cursor. Escape must clear it but report `false` so the Escape ladder
    /// still falls through to "clear search", as today.
    @Test("escapeClear on a cursor-only toggle set clears it but reports nothing visible")
    func escapeClearOnCursorOnlySetReportsFalse() {
        var s = PanelSelection()
        s.shiftMove(by: 1, ids: ids)
        s.shiftMove(by: -1, ids: ids)
        #expect(s.toggledIDs == [10])
        #expect(s.anchor == 0)
        #expect(s.cursor == 0)
        #expect(s.escapeClear(ids: ids) == false)
        #expect(s.toggledIDs.isEmpty)
    }

    @Test("escapeClear on a bare cursor reports nothing visible")
    func escapeClearOnBareCursorReportsFalse() {
        var s = PanelSelection()
        #expect(s.escapeClear(ids: ids) == false)
    }

    /// The cursor can sit past the end of an empty list — a search that matches
    /// nothing, or deleting the last rows — and Escape is reachable there. The
    /// cursor-row lookup must fall back rather than trap, and a set that somehow
    /// outlived its rows still counts as visible so the press clears it.
    @Test("escapeClear tolerates a cursor past the end of an empty list")
    func escapeClearWithOutOfRangeCursor() {
        var s = PanelSelection()
        s.shiftClick(at: 3, ids: ids)
        s.clampAndPrune(ids: [])          // list emptied under the selection
        #expect(s.escapeClear(ids: []) == false)
        #expect(s.toggledIDs.isEmpty)

        var stale = PanelSelection()
        stale.shiftClick(at: 0, ids: ids)
        stale.shiftClick(at: 2, ids: ids)
        #expect(stale.escapeClear(ids: []) == true)   // no cursor row to excuse them
        #expect(stale.toggledIDs.isEmpty)
    }

    /// A single Shift+Click highlights only the cursor row (Shift+Click moves the
    /// cursor onto it), so it is also visually indistinguishable from a bare cursor.
    @Test("escapeClear after one Shift+Click reports nothing visible")
    func escapeClearAfterSingleShiftClickReportsFalse() {
        var s = PanelSelection()
        s.shiftClick(at: 2, ids: ids)
        #expect(s.escapeClear(ids: ids) == false)
        #expect(s.toggledIDs.isEmpty)
    }

    @Test("escapeClear on a cherry-picked set clears everything and reports true")
    func escapeClearOnCherryPickedSetReportsTrue() {
        var s = PanelSelection()
        s.shiftClick(at: 0, ids: ids)
        s.shiftClick(at: 3, ids: ids)
        #expect(s.escapeClear(ids: ids) == true)
        #expect(s.toggledIDs.isEmpty)
        #expect(s.anchor == s.cursor)
        #expect(s.cursor == 3)   // the cursor stays where it was; only selection clears
    }

    /// The case an index-only heuristic gets wrong: toggling two rows then toggling
    /// the first back off leaves the cursor on the deselected row while the OTHER row
    /// stays highlighted. That highlight is visible, so this press must consume the
    /// selection rung rather than also clearing the search field.
    @Test("escapeClear reports visible when the lone highlight is not the cursor row")
    func escapeClearOnNonCursorLoneHighlightReportsTrue() {
        var s = PanelSelection()
        s.shiftClick(at: 0, ids: ids)
        s.shiftClick(at: 1, ids: ids)
        s.shiftClick(at: 0, ids: ids)   // cursor lands on 0; row 1 stays selected
        #expect(s.toggledIDs == [ids[1]])
        #expect(s.cursor == 0)
        #expect(s.escapeClear(ids: ids) == true)
        #expect(s.toggledIDs.isEmpty)
    }

    @Test("escapeClear mid-shift-walk clears the range and reports true")
    func escapeClearMidWalkReportsTrue() {
        var s = PanelSelection()
        s.shiftMove(by: 1, ids: ids)
        #expect(s.escapeClear(ids: ids) == true)
        #expect(s.toggledIDs.isEmpty)
        #expect(s.anchor == 1)
        #expect(s.cursor == 1)
    }

    // MARK: - Plain arrows and collapse (R10)

    @Test("plainMove with a multi-selection collapses to the trailing edge going down")
    func plainMoveDownCollapsesToMaxIndex() {
        var s = PanelSelection()
        s.shiftClick(at: 1, ids: ids)
        s.shiftClick(at: 4, ids: ids)
        s.plainMove(by: 1, ids: ids)
        #expect(s.anchor == 4)
        #expect(s.cursor == 4)
        #expect(s.toggledIDs.isEmpty)
        #expect(s.selectedIndices(ids: ids) == [4])
    }

    @Test("plainMove with a multi-selection collapses to the leading edge going up")
    func plainMoveUpCollapsesToMinIndex() {
        var s = PanelSelection()
        s.shiftClick(at: 1, ids: ids)
        s.shiftClick(at: 4, ids: ids)
        s.plainMove(by: -1, ids: ids)
        #expect(s.cursor == 1)
        #expect(s.anchor == 1)
        #expect(s.toggledIDs.isEmpty)
    }

    @Test("plainMove without a multi-selection wrap-moves as today")
    func plainMoveWrapsWithoutMulti() {
        var s = PanelSelection()
        s.plainMove(by: -1, ids: ids)
        #expect(s.cursor == 4)
        s.plainMove(by: 1, ids: ids)
        #expect(s.cursor == 0)
    }

    /// A lone toggled row is not a multi-selection, so the arrow still wrap-moves
    /// (and drops the toggle) exactly like today's single-selection navigation.
    @Test("plainMove from a single toggled row moves and clears the toggle")
    func plainMoveFromSingleToggleMoves() {
        var s = PanelSelection()
        s.shiftClick(at: 2, ids: ids)
        s.plainMove(by: 1, ids: ids)
        #expect(s.cursor == 3)
        #expect(s.toggledIDs.isEmpty)
    }

    /// Command modes have no record IDs (rows are keyed by name), so they drive the
    /// cursor through the count-only overload; the toggled set stays empty there.
    @Test("count-only plainMove wraps in both directions and never toggles")
    func countOnlyPlainMoveWraps() {
        var s = PanelSelection()
        s.plainMove(by: -1, count: 3)
        #expect(s.cursor == 2)
        #expect(s.anchor == 2)
        s.plainMove(by: 1, count: 3)
        #expect(s.cursor == 0)
        #expect(s.toggledIDs.isEmpty)
    }

    @Test("count-only plainMove on an empty list is a no-op")
    func countOnlyPlainMoveEmptyList() {
        var s = PanelSelection()
        s.plainMove(by: 1, count: 0)
        #expect(s.cursor == 0)
    }

    @Test("collapse clears the toggles and lands both indices on the target")
    func collapseClearsAndLands() {
        var s = PanelSelection()
        s.shiftClick(at: 0, ids: ids)
        s.shiftClick(at: 3, ids: ids)
        s.collapse(to: 2, ids: ids)
        #expect(s.toggledIDs.isEmpty)
        #expect(s.anchor == 2)
        #expect(s.cursor == 2)
        #expect(s.effectiveIDs(ids: ids) == [30])
    }

    @Test("reset returns the model to its initial state")
    func resetRestoresInitialState() {
        var s = PanelSelection()
        s.shiftClick(at: 3, ids: ids)
        s.shiftMove(by: 1, ids: ids)
        s.reset()
        #expect(s == PanelSelection())
    }

    // MARK: - List churn: prune and clamp

    @Test("clampAndPrune drops absent IDs and clamps indices into the shorter list")
    func clampAndPruneDropsAndClamps() {
        var s = PanelSelection()
        s.shiftClick(at: 0, ids: ids)   // id 10
        s.shiftClick(at: 4, ids: ids)   // id 50; cursor = anchor = 4
        s.clampAndPrune(ids: [10, 20, 30])
        #expect(s.toggledIDs == [10])
        #expect(s.anchor == 2)
        #expect(s.cursor == 2)
    }

    @Test("clampAndPrune can empty the selection, and the cursor floor takes over")
    func clampAndPruneCanEmptySelection() {
        var s = PanelSelection()
        s.shiftClick(at: 3, ids: ids)   // id 40
        s.clampAndPrune(ids: [10, 20, 30])
        #expect(s.toggledIDs.isEmpty)
        #expect(s.cursor == 2)
        #expect(s.effectiveIDs(ids: [10, 20, 30]) == [30])
    }

    /// A toggled ID that is no longer in the list (a filter change or a fresh
    /// observation the panel has not pruned yet) must be inert, never a phantom
    /// selection member.
    @Test("a stale toggled ID is excluded from the effective selection and its count")
    func staleToggledIDIsInert() {
        let shorter: [Int64] = [10, 20, 30, 40]

        var onlyStale = PanelSelection()
        onlyStale.shiftClick(at: 4, ids: ids)   // id 50 — absent from `shorter`
        #expect(onlyStale.effectiveIDs(ids: shorter) == [40])   // cursor floor, clamped
        #expect(onlyStale.selectedIndices(ids: shorter) == [3])
        #expect(!onlyStale.hasMultiSelection(ids: shorter))

        var mixed = PanelSelection()
        mixed.shiftClick(at: 1, ids: ids)       // id 20 — live
        mixed.shiftClick(at: 4, ids: ids)       // id 50 — stale
        #expect(mixed.effectiveIDs(ids: shorter) == [20])
        #expect(!mixed.hasMultiSelection(ids: shorter))
    }

    /// KTD3: the floor of one applies only when the list has rows. Zero visible rows
    /// means an empty selection, so paste/delete/drag no-op instead of acting on a
    /// row that isn't there.
    @Test("an empty list yields an empty selection, not a phantom cursor row")
    func emptyListYieldsEmptySelection() {
        var s = PanelSelection()
        s.shiftClick(at: 0, ids: ids)
        #expect(s.effectiveIDs(ids: []) == [])
        #expect(s.selectedIndices(ids: []) == [])
        #expect(!s.hasMultiSelection(ids: []))
    }

    @Test("moves on an empty list are no-ops")
    func movesOnEmptyListAreNoOps() {
        var s = PanelSelection()
        s.shiftMove(by: 1, ids: [])
        s.plainMove(by: 1, ids: [])
        #expect(s == PanelSelection())
    }

    // MARK: - hasMultiSelection (R10 gate)

    static let multiSelectionMatrix: [([Int], Bool)] = [
        ([], false),          // bare cursor
        ([2], false),         // one toggled row is still a single selection
        ([1, 3], true),       // cherry-picked pair
        ([0, 2, 4], true),
    ]

    @Test("hasMultiSelection counts the effective selection", arguments: multiSelectionMatrix)
    func hasMultiSelectionMatrix(toggled: [Int], expected: Bool) {
        var s = PanelSelection()
        for index in toggled { s.shiftClick(at: index, ids: ids) }
        #expect(s.hasMultiSelection(ids: ids) == expected)
    }

    @Test("hasMultiSelection is true mid-shift-walk of two rows")
    func hasMultiSelectionMidWalk() {
        var s = PanelSelection()
        s.shiftMove(by: 1, ids: ids)
        #expect(s.hasMultiSelection(ids: ids))
    }

    // MARK: - Delete repositioning (R5)

    /// `expected` is an index in the POST-delete list.
    static let deleteMatrix: [(Set<Int>, Int, Int)] = [
        ([1, 3], 5, 2),               // survivors 0,2,4 → the row after 3 (old 4) → new 2
        ([2], 5, 2),                  // survivors 0,1,3,4 → old 3 → new 2
        ([0], 5, 0),                  // survivors 1,2,3,4 → old 1 → new 0
        ([3, 4], 5, 2),               // tail gone → last survivor (old 2) → new 2
        ([4], 5, 3),                  // last row gone → last survivor (old 3) → new 3
        ([0, 1, 2, 3, 4], 5, 0),      // everything gone → 0
        ([], 5, 0),                   // nothing deleted → 0 (callers guard on empty)
    ]

    @Test("indexAfterDeleting lands on a sensible survivor", arguments: deleteMatrix)
    func indexAfterDeletingMatrix(deleted: Set<Int>, count: Int, expected: Int) {
        #expect(PanelSelection.indexAfterDeleting(deleted: deleted, count: count) == expected)
    }

    @Test("indexAfterDeleting ignores indices outside the list")
    func indexAfterDeletingIgnoresOutOfRange() {
        #expect(PanelSelection.indexAfterDeleting(deleted: [99], count: 5) == 0)
        #expect(PanelSelection.indexAfterDeleting(deleted: [1, 99], count: 5) == 1)
    }
}
