# Content Type Filter Tabs

**Date:** 2026-04-03
**Status:** Brainstorm complete

## What We're Building

Horizontal pill-style filter tabs in the main clipboard history view, positioned between the search bar and the item list. Lets users filter clipboard history by content type: All, Text, Image, GIF, Video. Reuses the same visual pattern as the `/sleep` command's "Keep Awake" / "Closed Lid" section tabs.

## Why This Approach

The `/sleep` section tabs already solve the "filter a list by category" problem with a proven keyboard-first UX. Applying the same pattern to the main view keeps the app internally consistent and avoids inventing new interaction paradigms. Horizontal pills above the list is the most natural placement — it mirrors the existing command options UI and doesn't eat horizontal space from the item list.

## Key Decisions

### Layout
- **Tab row is always visible** — no layout shifts. Consistent UI regardless of history contents.
- **Tabs for empty types are hidden** — if you have no videos, the "Video" tab doesn't appear. Tab count is dynamic.
- **"All" tab is always present** and is the default when the panel opens.
- Positioned between the search bar divider and the item list, same as command section tabs.

### Keyboard Navigation
- **Left/Right arrows** switch between filter tabs (same as `/sleep` sections).
- **Up/Down arrows** navigate within the filtered item list.
- **Cmd+Right** enters edit mode (replaces plain Right arrow, which now switches tabs).
- Selecting a tab resets cursor to 0 (top of filtered list).

### Search + Filter Interaction
- Search text and type filter **combine** — selecting "Image" then typing "screenshot" shows only images matching "screenshot".
- The database query applies both the FTS search and the `kind` filter simultaneously.
- Selecting a filter tab does NOT clear the search text, and typing does NOT reset the filter.

### Footer Hint
- Update the keyboard hint bar to reflect new navigation: `← → filter  ↑ ↓ navigate  ⏎ paste`

## Implementation Sketch (high-level)

1. Add `@State private var activeFilter: Int = 0` to PanelView (same pattern as `activeSection`).
2. Compute available filters from current items (count per kind), always including "All" at index 0.
3. Add a pill-tab `HStack` view between the divider and `clipboardList`, reusing the section tab styling from command options.
4. Modify `startObservation()` / the GRDB query to include an optional `kind` filter parameter.
5. Remap keyboard: Left/Right → filter switching in clipboard mode, Cmd+Right → edit mode.
6. Reset `activeFilter = 0` when panel disappears (same as `activeSection` reset).

## Open Questions

- Should tabs show item counts (e.g., "Text (42)")? Or keep it clean with just the label?
- When a filtered view is empty after a search, should we show a specific empty state like "No images matching 'foo'"?
