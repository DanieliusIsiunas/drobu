import Foundation

/// Pure selection model for the clipboard panel: which rows are selected, where the
/// keyboard cursor is, and how every gesture moves both. Kept free of AppKit,
/// SwiftUI, and the database so the whole grow/shrink/cherry-pick matrix is directly
/// unit-testable (the `CropGeometry` / `DragExport` / `shiftTapDecision` precedent);
/// `PanelView` owns one `@State PanelSelection` and reads it for rendering, paste,
/// delete, and drag-out.
///
/// **State shape (KTD3): one ID set with a materialized live range.** There is no
/// separate "range" at query time — a Shift+Arrow *materializes* its
/// `anchor...cursor` span into `toggledIDs`, replacing its own previous
/// contribution (remove the old range's IDs, insert the new range's IDs). That's
/// NSTableView's semantics, and it is what makes grow AND shrink work off a single
/// set: an implementation that only ever unioned would leave ghost rows selected
/// after a shrink. The cost is the two pinned quirks documented on `shiftMove`.
///
/// **Toggles are keyed by record ID, not index (KTD4).** A new clipboard item
/// arriving at the top shifts every index by one; ID-keyed toggles keep pointing at
/// the rows the user actually picked. (Follows the `editingItemId` precedent in
/// `PanelView`. Accepted limit: `ClipboardRecord.upsert` deletes and re-inserts on
/// re-copy, so a re-copied item gets a new ID and silently leaves the selection.)
///
/// **Effective selection = the toggled IDs in list order, or else the cursor row.**
/// The cursor fallback is a *floor of one*: every downstream consumer (paste,
/// delete, drag, preview) assumes at least one selected item, so a bare cursor
/// behaves exactly like today's single selection. The floor applies only when the
/// list has rows — with `ids` empty the selection is empty and those consumers
/// no-op, matching today's empty-items guard in `selectedItems`.
///
/// Every operation takes the current list-order `ids` (or just a count) as input, so
/// the model never holds a stale copy of the list. Indices are clamped, never
/// trapped: the list can shrink underneath the panel between a gesture and the next
/// observation tick.
struct PanelSelection: Equatable {

    /// Rows the user has explicitly put in the selection — by Shift+Click, or by a
    /// Shift+Arrow materializing its range. Empty means "just the cursor row".
    /// IDs absent from the current list are inert (see `selectedIndices`), so a
    /// pending prune can never surface a phantom row.
    private(set) var toggledIDs: Set<Int64> = []

    /// Where the current Shift+Arrow range extension started.
    private(set) var anchor: Int = 0

    /// The keyboard cursor — the row the previews follow and the row Return pastes
    /// when nothing is toggled.
    private(set) var cursor: Int = 0

    // MARK: - Gestures

    /// Shift+Click: toggle `ids[index]` in or out of the selection, and move BOTH
    /// indices onto it (KTD8) — the previews show the row just acted on and a
    /// following Shift+Arrow extends from it. The cursor moving onto a
    /// just-toggled-*off* row does not re-select it, because the cursor is only a
    /// fallback for an empty toggled set.
    mutating func shiftClick(at index: Int, ids: [Int64]) {
        guard ids.indices.contains(index) else { return }
        let id = ids[index]
        if toggledIDs.contains(id) {
            toggledIDs.remove(id)
        } else {
            toggledIDs.insert(id)
        }
        anchor = index
        cursor = index
    }

    /// Collapse to a single row: drop every toggle and put both indices on `index`.
    /// Drives a plain press outside the selection, Cmd+1..9, and the edit-follow
    /// reposition.
    mutating func collapse(to index: Int, ids: [Int64]) {
        toggledIDs.removeAll()
        anchor = clamped(index, count: ids.count)
        cursor = anchor
    }

    /// Shift+Arrow: move the cursor by `delta` (clamped, never wrapping — R3) and
    /// re-materialize the `anchor...cursor` range, replacing the range's previous
    /// contribution to the set. Rows toggled outside the range are untouched and
    /// persist alongside it.
    ///
    /// Two consequences are PINNED BEHAVIOR — they fall out of "the range owns its
    /// span" and match NSTableView. Do not "fix" them; both are unit-tested:
    ///
    /// 1. A cherry-picked row the range grows *over* is absorbed into the range, so
    ///    shrinking the range back past it deselects it.
    /// 2. Shift+Arrowing away from a row just toggled OFF re-includes that row,
    ///    because it is the anchor and therefore inside the new range.
    mutating func shiftMove(by delta: Int, ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let previousRange = rangeIDs(ids: ids)
        cursor = clamped(cursor + delta, count: ids.count)
        toggledIDs.subtract(previousRange)
        toggledIDs.formUnion(rangeIDs(ids: ids))
    }

    /// Plain Arrow. With a multi-selection active this collapses onto the selection's
    /// trailing edge when moving down and its leading edge when moving up — the row
    /// the user "walked to" — instead of stepping past it (today's behavior). With a
    /// single selection it wrap-moves, also as today. Either way the toggles clear:
    /// a plain arrow always ends in a single selection.
    mutating func plainMove(by delta: Int, ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let target: Int
        let selected = selectedIndices(ids: ids)
        if selected.count > 1 {
            target = delta > 0 ? (selected.last ?? cursor) : (selected.first ?? cursor)
        } else {
            target = wrapped(cursor + delta, count: ids.count)
        }
        toggledIDs.removeAll()
        anchor = clamped(target, count: ids.count)
        cursor = anchor
    }

    /// Count-only plain arrow for the command modes (`/sleep` command list and its
    /// option lists). Those rows are keyed by name, not record ID, so the ID-based
    /// signatures cannot serve them — and the toggled set is always empty there,
    /// since multi-selection is a clipboard-mode concept only.
    mutating func plainMove(by delta: Int, count: Int) {
        guard count > 0 else { return }
        toggledIDs.removeAll()
        anchor = wrapped(cursor + delta, count: count)
        cursor = anchor
    }

    /// Escape's selection rung: clear the selection and re-seat the anchor on the
    /// cursor. Returns whether anything the user could SEE was cleared, so the
    /// caller's Escape ladder (selection → clear search → close panel) advances by
    /// exactly one visible step per press.
    ///
    /// The load-bearing case is a toggled set holding exactly the cursor row's own
    /// ID — what a Shift+Down/Shift+Up round-trip leaves, and also what a single
    /// Shift+Click leaves (the click moves the cursor onto that row). It renders
    /// identically to a bare cursor, so it is cleared but reported as `false` and
    /// Escape falls through to the search rung exactly as it does today.
    ///
    /// `ids` is what makes that test exact rather than a proxy. Comparing against
    /// `ids[cursor]` distinguishes "the lone highlight IS the cursor row" (invisible,
    /// report `false`) from "a different row is still highlighted" — reachable by
    /// toggling two rows then toggling the first back off, which leaves the cursor on
    /// the deselected row while the other stays lit. An index-only heuristic reports
    /// that second case as invisible and lets one press clear the search field too.
    mutating func escapeClear(ids: [Int64]) -> Bool {
        let cursorID = ids.indices.contains(cursor) ? ids[cursor] : nil
        // Visible iff the set holds anything other than the cursor row's own ID.
        let clearedSomethingVisible = !toggledIDs.isEmpty
            && !(toggledIDs.count == 1 && cursorID != nil && toggledIDs.contains(cursorID!))
        toggledIDs.removeAll()
        anchor = cursor
        return clearedSomethingVisible
    }

    /// Full reset to the top of the list — the search/filter/mode-change sites.
    mutating func reset() {
        toggledIDs.removeAll()
        anchor = 0
        cursor = 0
    }

    /// Reconcile with a refreshed list: drop toggled IDs whose rows are gone and pull
    /// both indices back inside bounds. Mirrors today's `refilterItems` clamp, and
    /// keeps `toggledIDs` from growing without bound across a long session.
    mutating func clampAndPrune(ids: [Int64]) {
        toggledIDs.formIntersection(ids)
        let maxIndex = max(0, ids.count - 1)
        anchor = min(max(anchor, 0), maxIndex)
        cursor = min(max(cursor, 0), maxIndex)
    }

    // MARK: - Queries

    /// The selected rows as ascending list indices — what rendering (`isSelected`,
    /// the Return affordance) and the drag participants consume.
    ///
    /// Toggled IDs missing from `ids` are skipped, so a not-yet-pruned selection is
    /// inert rather than phantom. O(n): a caller rendering n rows should compute this
    /// ONCE per body pass and index into it, not call it per row.
    func selectedIndices(ids: [Int64]) -> [Int] {
        guard !ids.isEmpty else { return [] }
        let toggled = ids.indices.filter { toggledIDs.contains(ids[$0]) }
        // Floor of one: an empty toggled set means "the cursor row".
        return toggled.isEmpty ? [clamped(cursor, count: ids.count)] : toggled
    }

    /// The selected rows' record IDs in list order — the paste/delete/drag order
    /// (R4: top to bottom, never click order).
    func effectiveIDs(ids: [Int64]) -> [Int64] {
        selectedIndices(ids: ids).map { ids[$0] }
    }

    /// Whether more than one row is effectively selected — the single predicate
    /// behind every multi-selection gate (⌘→ edit entry, footer verbs, drag
    /// participants). A lone toggled row is NOT a multi-selection: it behaves
    /// exactly like today's single selection.
    func hasMultiSelection(ids: [Int64]) -> Bool {
        selectedIndices(ids: ids).count > 1
    }

    // MARK: - Delete repositioning

    /// Where the cursor should land after deleting `deleted` (indices in the list of
    /// `count` rows). Returns an index in the POST-delete list.
    ///
    /// Rule: the first surviving row *after* the last deleted one (so the cursor
    /// keeps moving down the list the way it does for a single delete), else the last
    /// survivor when the tail was deleted, else 0 for an emptied list. Handles a
    /// sparse `deleted` set — the whole point of cherry-picked deletes (R5) — where
    /// today's `max(anchor, cursor) + 1` arithmetic would over-count the rows removed
    /// above the landing row.
    ///
    /// Static because it is a pure function of its arguments, not of the selection
    /// state (the caller derives `deleted` from `selectedIndices(ids:)`). Indices
    /// outside `0..<count` are ignored; an empty (or fully out-of-range) `deleted`
    /// set returns 0 — callers guard on an empty deletion before getting here.
    static func indexAfterDeleting(deleted: Set<Int>, count: Int) -> Int {
        let removed = deleted.filter { $0 >= 0 && $0 < count }
        guard let lastRemoved = removed.max() else { return 0 }
        let survivors = (0..<count).filter { !removed.contains($0) }
        guard !survivors.isEmpty else { return 0 }
        // `survivors` is ascending, so its own offsets ARE the post-delete indices.
        if let landing = survivors.firstIndex(where: { $0 > lastRemoved }) {
            return landing
        }
        return survivors.count - 1
    }

    // MARK: - Internals

    /// The IDs currently spanned by `anchor...cursor`, intersected with the list's
    /// bounds. This is the range's "contribution" that `shiftMove` replaces.
    private func rangeIDs(ids: [Int64]) -> [Int64] {
        let lower = max(0, min(anchor, cursor))
        let upper = min(ids.count - 1, max(anchor, cursor))
        guard lower <= upper else { return [] }
        return Array(ids[lower...upper])
    }

    /// Clamp into `0..<count` (0 for an empty list) — no wrap.
    private func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// Wrap into `0..<count`, tolerating a negative input (Swift's `%` keeps the
    /// sign of the dividend, so `-1 % 5` is `-1`, not `4`).
    private func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }
}
