# Multi-Select & Paste

**Date:** 2026-02-09

## What We're Building

Shift+Arrow multi-select in the clipboard history panel. Select a contiguous range of items, press Enter, and all selected items are pasted into the target app.

**Core use case:** Take 4 screenshots, open clipboard history, Shift+Down to select all 4, press Enter, and all images are pasted into Claude Code CLI.

## Why This Approach

### The fundamental problem

macOS NSPasteboard supports writing multiple items (`writeObjects`), but almost no app reads more than the first one. Claude Code CLI uses `osascript -e 'the clipboard as <<class PNGf>>'` which reads only one image. Maccy's maintainer abandoned multi-select for this exact reason.

### Sequential auto-paste solves it

Instead of putting all items on the pasteboard at once, the app pastes them **one at a time** automatically:

```
Close panel -> Write item 1 to pasteboard -> Cmd+V -> delay -> Write item 2 -> Cmd+V -> delay -> ...
```

This works with every app because each paste is a standard single-item operation.

## Key Decisions

1. **Selection model:** Shift+Arrow extends selection as a contiguous range (like Excel rows). No Cmd+Click for non-contiguous selection in v1.

2. **Paste order:** List order (most recent first, matching visual order top-to-bottom).

3. **Text handling:** When all selected items are text, concatenate them into one string (newline-separated) and paste once with a single Cmd+V.

4. **Image handling:** Each image is pasted individually with a delay between each Cmd+V.

5. **Mixed content (text + images):** Group by type — concatenate all text items into one paste first, then paste each image individually.

6. **Visual style:** All selected items get the accent color highlight (same style as current single-selection, applied to the entire range). No numbered badges.

7. **Preview panel:** Shows the last item in the selection (or a count indicator like "4 items selected").

## Interaction Details

- **Shift+Down Arrow:** Extends selection downward (adds next item to range)
- **Shift+Up Arrow:** Extends selection upward (adds previous item to range)
- **Arrow without Shift:** Collapses back to single selection (standard behavior)
- **Enter:** Pastes all selected items
- **Escape:** First press clears selection back to single, second press closes panel (or clears search first)
- **Cmd+1-9:** Remains single-item paste (no change)
- **Delete:** Deletes all selected items

## Open Questions

- Optimal delay between sequential pastes (likely 50-100ms, needs testing with Claude Code)
- Whether to show a subtle progress indicator during multi-paste sequence
- Whether Shift+Click (mouse) should also work for range selection (future enhancement)
