---
title: "feat: Add content type filter tabs to clipboard history"
type: feat
date: 2026-04-03
---

# feat: Add content type filter tabs to clipboard history

## Overview

Add horizontal pill-style filter tabs (All, Text, Image, GIF, Video) between the search bar and the clipboard history list. Reuses the exact visual pattern from `/sleep` command section tabs. Left/Right arrows switch tabs, Cmd+Right enters edit mode (replacing plain Right arrow). Search and filter combine — both narrow results simultaneously.

Brainstorm: `docs/brainstorms/2026-04-03-content-type-filter-tabs-brainstorm.md`

## Proposed Solution

### Layout

```
┌──────────────────────────────┐
│ 🔍 Search...                 │
├──────────────────────────────┤
│ All  Text  Image  GIF  Video │  ← new filter tabs row
├──────────────────────────────┤
│ ▸ Item 1                     │
│   Item 2                     │
│   ...                        │
├──────────────────────────────┤
│ ← → filter  ↑ ↓ navigate  ⏎ │  ← new footer hint
└──────────────────────────────┘
```

- "All" tab always present, always at index 0, always the default
- Other tabs only shown if items of that type exist in the database
- Tabs disappear dynamically when their type is emptied (e.g., delete last GIF → GIF tab vanishes)
- If active filter's type is emptied, auto-reset to "All"

### Keyboard

| Key | Current behavior | New behavior |
|-----|-----------------|-------------|
| Right arrow | Enter edit mode (text/GIF/video) | Switch to next filter tab |
| Left arrow | Unhandled (falls to search field) | Switch to previous filter tab |
| Cmd+Right | Unhandled | Enter edit mode (text/GIF/video) |
| Up/Down | Navigate list | Navigate list (unchanged) |
| Shift+Left/Right | N/A | Ignored (no tab switching with modifiers) |

**Trade-off:** Left/Right always consumed by tab switching — search field cursor cannot be moved with arrow keys. Acceptable: search is a narrow single-line field, users type/delete/retype. Matches existing behavior in command options mode where Left/Right switch sections.

**Edit mode safety:** During editing (`isEditing == true`), all keys return `.ignored` (line 512), so Cmd+Right does normal text editing. Cmd+Right only triggers `enterEditMode()` when NOT already editing.

### Query Strategy

Filter in SQL for accuracy (returns true 200 items of that type, not a subset of 200 mixed items filtered in-memory).

**Two queries in one observation block:**

```swift
ValueObservation.tracking { db in
    let availableKinds = try String.fetchAll(db, sql:
        "SELECT DISTINCT kind FROM clipboardItem ORDER BY kind")
    let items = try ClipboardRecord.search(query: query, kind: filterKind, in: db)
    return (availableKinds, items)
}
```

This ensures both tab visibility and list contents update reactively on any DB change.

**Search + non-text types:** FTS5 only indexes `plainText`. Images/GIFs typically have no `plainText`, so searching with an Image/GIF filter returns zero results. This is correct behavior — images don't have searchable text. Videos have `plainText` like "Screen Recording (0:15)" so search partially works for them.

## Technical Approach

### Files to modify

1. **`Sources/Models/ClipboardRecord.swift`** — Add `kind` parameter to `search()` and `fetchRecent()`
2. **`Sources/Views/PanelView.swift`** — Filter tabs UI, keyboard remapping, observation changes, state management, footer hint

### Phase 1: Query layer (`ClipboardRecord.swift`)

Add optional `kind` parameter to both query methods:

**`fetchRecent()` (line 46):**
```swift
static func fetchRecent(in db: Database, kind: String? = nil, limit: Int = 200) throws -> [ClipboardRecord] {
    var request = ClipboardRecord.order(Column("createdAt").desc).limit(limit)
    if let kind { request = request.filter(Column("kind") == kind) }
    return try request.fetchAll(db)
}
```

**`search()` (line 55):**
```swift
static func search(query: String, kind: String? = nil, in db: Database, limit: Int = 200) throws -> [ClipboardRecord]
```

When `kind` is provided and query is non-empty, add `AND clipboardItem.kind = \(kind)` to the WHERE clause in the SQL request (line 74-81). When `kind` is provided and query is empty, pass `kind` to `fetchRecent()`.

### Phase 2: State & observation (`PanelView.swift`)

**New state:**
```swift
@State private var activeFilter: Int = 0           // index into availableFilters
@State private var availableKinds: [String] = []   // distinct kinds from DB
```

**Computed property for filter tabs:**
```swift
private var availableFilters: [(label: String, kind: String?)] {
    var filters: [(String, String?)] = [("All", nil)]
    let order = [ClipboardRecord.kindText, .kindImage, .kindGif, .kindVideo]
    let labels = ["Text", "Image", "GIF", "Video"]
    for (kind, label) in zip(order, labels) {
        if availableKinds.contains(kind) { filters.append((label, kind)) }
    }
    return filters
}

private var activeFilterKind: String? {
    guard activeFilter < availableFilters.count else { return nil }
    return availableFilters[activeFilter].kind
}
```

**Modified `startObservation()` (line 715):**
Change the observation to return a tuple `(availableKinds: [String], items: [ClipboardRecord])`. In the `onChange` callback, update both `availableKinds` and `items`. After updating, guard that `activeFilter` is still valid — if the active filter's kind is no longer in `availableKinds`, reset `activeFilter = 0`.

Re-trigger observation when `activeFilter` changes — add `onChange(of: activeFilter)` that calls `startObservation()`, similar to how `onChange(of: searchText)` already does.

### Phase 3: Filter tabs view (`PanelView.swift`)

Reuse the `sectionTabs()` pattern (line 402-427). Create a new `filterTabs()` ViewBuilder:

```swift
@ViewBuilder
private func filterTabs() -> some View {
    HStack(spacing: 6) {
        ForEach(Array(availableFilters.enumerated()), id: \.offset) { index, filter in
            Text(filter.label)
                .font(.system(size: 13, weight: index == activeFilter ? .semibold : .regular))
                .foregroundStyle(index == activeFilter ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(index == activeFilter ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                )
                .onTapGesture {
                    if activeFilter != index {
                        activeFilter = index
                        cursor = 0
                        anchor = 0
                    }
                }
        }
        Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
}
```

Insert `filterTabs()` in `clipboardList` (line ~284) between the divider and the ScrollViewReader. Only show in `.clipboard` mode.

### Phase 4: Keyboard remapping (`PanelView.swift`)

**`handleClipboardKeyPress()` (line 510):**

Replace the `.rightArrow` case (lines 515-533):

```swift
case .rightArrow:
    // Cmd+Right → enter edit mode (replaces plain Right)
    if press.modifiers.contains(.command) {
        guard !items.isEmpty, !hasMultiSelection else { return .ignored }
        let item = items[cursor]
        // ... existing editability checks for text/gif/video ...
        enterEditMode()
        return .handled
    }
    // Plain Right → next filter tab (no modifiers only)
    guard press.modifiers.isEmpty else { return .ignored }
    let filters = availableFilters
    if activeFilter < filters.count - 1 {
        activeFilter += 1
        cursor = 0
        anchor = 0
    }
    return .handled
```

Add a new `.leftArrow` case (currently unhandled):

```swift
case .leftArrow:
    guard press.modifiers.isEmpty else { return .ignored }
    if activeFilter > 0 {
        activeFilter -= 1
        cursor = 0
        anchor = 0
    }
    return .handled
```

### Phase 5: Footer hint & reset

**Footer hint:** Add a `Text` view below the `clipboardList` scroll area (after the list, before the bottom edge):

```swift
Divider()
Text("\u{2190}\u{2192} filter  \u{2191}\u{2193} navigate  \u{21B5} paste")
    .font(.system(size: 11))
    .foregroundStyle(.tertiary)
    .padding(.vertical, 4)
```

**Panel disappear reset (line 181):** Add `activeFilter = 0` to the `.onDisappear` block alongside the existing `activeSection = 0`.

## Acceptance Criteria

- [x] Filter tabs visible between search bar and list in clipboard mode
- [x] "All" tab always present and selected by default on panel open
- [x] Tabs for types with zero items are hidden
- [x] Left/Right arrows switch between visible tabs
- [x] Cmd+Right enters edit mode for editable items (text, GIF, video)
- [x] Tab switching resets cursor to first item in filtered list
- [x] Search text + type filter combine (both applied in SQL query)
- [x] Selecting a tab does not clear search text; typing does not reset filter
- [x] Active tab auto-resets to "All" if its type becomes empty (items deleted/expired)
- [x] Filter resets to "All" on panel close
- [x] Mouse click on tabs works (`.onTapGesture`)
- [x] Cmd+1..9 shortcuts work correctly with filtered list
- [x] Footer hint shows `← → filter  ↑ ↓ navigate  ⏎ paste`
- [x] Panel height accommodates new tab row and footer without clipping

## Edge Cases

| Scenario | Expected behavior |
|----------|------------------|
| Only text items in DB | Tabs: "All", "Text" |
| No items at all | Tabs: "All" only (no type tabs) |
| Delete last GIF while GIF tab active | GIF tab disappears, auto-reset to "All" |
| Search "hello" + Image filter | FTS + kind=image → likely 0 results (images have no text). Show empty state. |
| Search "recording" + Video filter | FTS matches videos with "Screen Recording" in plainText |
| Right arrow on last tab | No-op (clamp, no wrap) |
| Left arrow on "All" tab | No-op (already at start) |
| Shift+Right/Left | Ignored (`.ignored`) — modifiers bypass tab switching |
| Panel opens → no filter persistence | Always starts at "All" |
| isEditing true → Cmd+Right | `.ignored` — NSTextView handles it normally |

## References

- Brainstorm: `docs/brainstorms/2026-04-03-content-type-filter-tabs-brainstorm.md`
- Section tabs pattern: `Sources/Views/PanelView.swift:402-427` (`sectionTabs()`)
- Keyboard handler: `Sources/Views/PanelView.swift:510-582` (`handleClipboardKeyPress()`)
- Query methods: `Sources/Models/ClipboardRecord.swift:46-83` (`fetchRecent`, `search`)
- Observation: `Sources/Views/PanelView.swift:715-740` (`startObservation()`)
- Panel reset: `Sources/Views/PanelView.swift:181-194` (`.onDisappear`)
