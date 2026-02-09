# Alfred-Style Split Layout for Clipboard History

**Date:** 2026-02-09
**Status:** Ready for planning

## What We're Building

A two-panel split layout matching Alfred's clipboard history UI:

**Left panel (~55% width) — Item List:**
- Source app icon (from bundle ID) + truncated text or image description
- Keyboard shortcuts (Cmd+1 through Cmd+9) on the right side of each row
- Return arrow icon on the selected row
- Highlighted selection state

**Right panel (~45% width) — Preview:**
- Full text preview for text items (scrollable for long content)
- Image preview scaled to fit for image items (maintain aspect ratio)
- Bottom metadata bar: word/char count for text, dimensions/size for images
- Timestamp: "Copied 8 Feb 2026 at 23:06"

**Search bar** stays at the top, spanning the full width.

## Why This Approach

**SwiftUI HStack with fixed-ratio split** — chosen over NSSplitViewController because:
- No resizable divider needed (fixed layout like Alfred)
- Stays within existing SwiftUI architecture
- Minimal code changes — preview reacts to existing `selectedIndex` state
- Compatible with panel recreation pattern (new SwiftUI tree each show)

## Key Decisions

1. **Window size:** 780x460 (from current 620x460) — matches Alfred proportions
2. **App icons:** Store `sourceBundleId` in a new DB column alongside existing `sourceApp` name. Use `NSWorkspace.shared.icon(forFile:)` with bundle path for icon lookup.
3. **Image preview:** Fit-to-fill with aspect ratio maintained (not scrollable original size)
4. **Preview always visible:** Right panel shown even when nothing selected (empty state)
5. **Layout approach:** Pure SwiftUI HStack, no AppKit NSSplitViewController

## Schema Change

Add `sourceBundleId TEXT` column to `clipboardItem` table. Capture via `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` at copy time.

## Row Redesign

Each row in the left panel:
```
[AppIcon 20x20] [Truncated text...        ] [Cmd+N or return arrow]
```

## Preview Panel

```
+----------------------------------+
|  Full text content (scrollable)  |
|  or                              |
|  Image preview (fit to fill)     |
|                                  |
|                                  |
|                                  |
|                                  |
+----------------------------------+
|  12 words; 79 chars              |
|  Copied 8 Feb 2026 at 23:06     |
+----------------------------------+
```

## Open Questions

- None — ready for implementation planning.
