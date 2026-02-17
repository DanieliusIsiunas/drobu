---
title: "feat: Add inline GIF trim editing"
type: feat
date: 2026-02-17
brainstorm: docs/brainstorms/2026-02-17-gif-editing-brainstorm.md
---

# feat: Add Inline GIF Trim Editing (Phase 2)

## Overview

Add GIF trimming directly in the clipboard panel's preview area. When a GIF item is selected, pressing right arrow enters trim mode — showing a frame-by-frame player with a timeline scrubber. Drag the start/end handles to select a range, preview plays only the selected frames. Cmd+Return saves the trimmed GIF in place; Escape discards.

## Problem Statement / Motivation

GIFs copied from the web are often longer than needed. Currently, trimming requires exporting to an external app (Gifox, Giphy, etc.), editing there, and re-copying. Phase 2 brings this editing inline — same keyboard-driven workflow as text editing, no app switching.

## Proposed Solution

Build three new components that mirror the text editing architecture:

1. **GIF Frame Engine** — CGImageSource/CGImageDestination wrapper for frame extraction and re-encoding
2. **GIF Trim Player** — NSViewRepresentable frame-by-frame renderer with range-limited playback
3. **Timeline Scrubber** — SwiftUI view with draggable start/end handles

Wire them into the existing edit mode state machine in ClipboardPanelView.

## Technical Approach

### Change 1: GIF Frame Engine

**New file:** `Sources/Services/GIFFrameEngine.swift`

Stateless utility for frame-level GIF operations using ImageIO:

```swift
struct GIFFrame {
    let image: CGImage
    let delay: Double  // seconds
}

enum GIFFrameEngine {
    /// Extract all frames and their delays from GIF data.
    static func extractFrames(from data: Data) -> [GIFFrame]

    /// Encode a subset of frames back into GIF data.
    static func encodeFrames(_ frames: [GIFFrame]) -> Data?
}
```

**extractFrames:**
- `CGImageSourceCreateWithData` to open the GIF
- Iterate `CGImageSourceGetCount` frames
- For each: `CGImageSourceCreateImageAtIndex` for the CGImage
- Extract delay from `kCGImagePropertyGIFDictionary` (same pattern as existing `gifMetadata()` in ClipboardRecord.swift:121-137)

**encodeFrames:**
- `CGImageDestinationCreateWithData` with `kUTTypeGIF` and frame count
- Set file-level GIF properties (loop count = 0 for infinite loop)
- For each frame: `CGImageDestinationAddImage` with per-frame delay in properties dict
- `CGImageDestinationFinalize` to produce the Data

### Change 2: GIF Trim Player (NSViewRepresentable)

**New file:** `Sources/Views/GIFTrimPlayerView.swift`

Custom frame-by-frame player that replaces AnimatedGIFView during trim mode. Unlike NSImageView (which plays all frames automatically), this gives us range control.

**Architecture:**
- NSView subclass with a `CALayer` for rendering (set `layer.contents = cgImage`)
- Timer-driven playback respecting per-frame delays
- Accepts `startFrame` and `endFrame` bindings — loops only within that range
- Reports `currentFrame` index back to SwiftUI (for scrubber position sync)
- Keyboard: Cmd+Return → save, Escape → discard (same pattern as EditableTextView.swift:10-20)

**Pattern reference:** EditableTextView.swift — NSViewRepresentable with Coordinator for callbacks, focus management on creation.

### Change 3: Timeline Scrubber

**New file:** `Sources/Views/TimelineScrubber.swift`

Pure SwiftUI view. A horizontal bar representing all frames, with two draggable handles for start and end positions.

**Structure:**
```
┌─────────────────────────────────────────┐
│  ◄|████████████████████████████|►        │
│   ^start                      ^end       │
│         ▲ playhead (current frame)       │
└─────────────────────────────────────────┘
```

**Props:**
- `frameCount: Int` — total frames in the GIF
- `@Binding var startFrame: Int` — left handle position
- `@Binding var endFrame: Int` — right handle position
- `currentFrame: Int` — playhead position (read-only, from player)

**Behavior:**
- Handles are draggable (SwiftUI `.gesture(DragGesture(...))`)
- Start handle can't pass end handle and vice versa (minimum 2 frames selected)
- Selected range highlighted (accent color), outside range dimmed
- Frame counter label: "Frames 12–48 of 96"
- Compact: fits in ~30px height below the preview

### Change 4: Integrate into PreviewPanel

**File:** `Sources/Views/PreviewPanel.swift`

The `gifPreview(for:)` method currently always shows `AnimatedGIFView`. In trim mode, switch to a trim editing view:

```swift
private func gifPreview(for item: ClipboardRecord) -> some View {
    Group {
        if isEditing, let data = item.imageData {
            // Trim mode: frame player + scrubber
            GIFTrimView(
                data: data,
                onSave: onSave,
                onDiscard: onDiscard
            )
        } else if let data = item.imageData {
            // Normal preview: animated NSImageView
            AnimatedGIFView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        } else { ... }
    }
}
```

**GIFTrimView** is a composition wrapper (new file or inline in PreviewPanel):
- VStack: GIFTrimPlayerView (top, fills space) + TimelineScrubber (bottom, fixed height)
- Manages shared state: `startFrame`, `endFrame`, `currentFrame`
- Extracts frames on appear using `GIFFrameEngine.extractFrames()`

**Metadata bar during edit:** Show live trim info — "Frames 12–48 of 96 | 1.8s (was 3.2s)"

### Change 5: Extend edit state in ClipboardPanelView

**File:** `Sources/Views/ClipboardPanelView.swift`

The right arrow key handler (line 142) currently guards on `kind == kindText`. Extend to also allow GIF:

```swift
case .rightArrow:
    guard !items.isEmpty, !hasMultiSelection else { return .ignored }
    let item = items[cursor]
    if item.kind == ClipboardRecord.kindText, item.plainText != nil {
        enterEditMode()
        return .handled
    }
    if item.kind == ClipboardRecord.kindGif, item.imageData != nil {
        enterEditMode()  // Same flag — PreviewPanel knows to show trim UI
        return .handled
    }
    return .ignored
```

**Save handler for GIF:** The existing `saveEdit()` handles text. Add a GIF branch:

```swift
private func saveEdit() {
    guard isEditing else { return }
    isEditing = false
    let savedItemId = editingItemId
    editingItemId = nil
    isSearchFocused = true

    if let item = items.first(where: { $0.id == savedItemId }) {
        if item.kind == ClipboardRecord.kindGif {
            saveGifTrim(itemId: savedItemId)
            return
        }
    }
    // ... existing text save logic
}
```

The `saveGifTrim` method gets the trimmed GIF data from the trim view and calls a new DB method.

### Change 6: Add updateGifData to ClipboardRecord

**File:** `Sources/Models/ClipboardRecord.swift`

New method following the `updatePlainText()` pattern (line 97):

```swift
static func updateGifData(id: Int64, newData: Data, in db: Database) throws {
    let newHash = sha256(newData)

    // Delete any other item with same hash (dedup)
    try db.execute(
        sql: "DELETE FROM clipboardItem WHERE contentHash = ? AND id != ?",
        arguments: [newHash, id]
    )

    // Update record in place
    try db.execute(
        sql: """
            UPDATE clipboardItem
            SET imageData = ?, contentHash = ?, createdAt = ?
            WHERE id = ?
            """,
        arguments: [newData, newHash, Date(), id]
    )
}
```

Same pattern: recalculate hash, dedup, update in place with fresh timestamp.

## Data Flow

```
Right Arrow (GIF selected)
    → isEditing = true, editingItemId = item.id
    → PreviewPanel switches: AnimatedGIFView → GIFTrimView
    → GIFTrimView extracts frames via GIFFrameEngine
    → Frame player loops startFrame..endFrame
    → User drags scrubber handles to adjust range
    → Cmd+Return:
        → GIFFrameEngine.encodeFrames(selectedSubset) → Data
        → ClipboardRecord.updateGifData(id:, newData:)
        → DB observation fires, item moves to top
    → Escape:
        → isEditing = false, no changes
```

## Acceptance Criteria

- [ ] Right arrow on a GIF item enters trim mode
- [ ] Trim mode shows frame-by-frame player with timeline scrubber below
- [ ] Dragging start/end handles adjusts the trim range
- [ ] Preview plays only the selected frame range in a loop
- [ ] Scrubber shows frame counter (e.g., "Frames 12–48 of 96")
- [ ] Cmd+Return saves: re-encodes selected frames as new GIF, updates DB record
- [ ] Escape discards changes, returns to normal preview
- [ ] ChromaSweepBorder activates during trim mode (already wired to isEditing)
- [ ] Metadata bar updates live during trim (showing new duration)
- [ ] Trimmed GIF moves to top of list (fresh createdAt)
- [ ] Trimmed GIF pastes correctly (GIF + PNG fallback, same as Phase 1)
- [ ] Panel close during trim auto-saves (existing behavior from text edit)
- [ ] Existing text editing unaffected

## Dependencies & Risks

**Low risk:**
- CGImageSource frame extraction is the same API already used for metadata
- CGImageDestination is mature and well-documented for GIF encoding
- Edit state machine is proven (text editing works)

**Medium risk:**
- **Memory for large GIFs:** A 20MB GIF with 500 frames = 500 CGImages in memory. Mitigate: extract frames lazily or use thumbnail-sized previews for the scrubber, full-size only for the player's current frame.
- **Frame player timing:** Per-frame delays vary in GIFs. Timer needs to respect individual delays, not use a fixed interval. Use `DispatchQueue.main.asyncAfter` with the current frame's delay.
- **Scrubber drag precision:** With 500+ frames, each pixel of scrubber width maps to multiple frames. May need snapping or zoom. Start simple — test with real GIFs and iterate.

## File Change Summary

| File | Type | Description |
|------|------|-------------|
| `Sources/Services/GIFFrameEngine.swift` | **New** | Frame extraction (CGImageSource) and re-encoding (CGImageDestination) |
| `Sources/Views/GIFTrimPlayerView.swift` | **New** | NSViewRepresentable frame-by-frame player with range support |
| `Sources/Views/TimelineScrubber.swift` | **New** | SwiftUI scrubber with draggable start/end handles |
| `Sources/Views/GIFTrimView.swift` | **New** | Composition: player + scrubber + state management |
| `Sources/Views/PreviewPanel.swift` | Edit | Switch to GIFTrimView when editing a GIF |
| `Sources/Views/ClipboardPanelView.swift` | Edit | Allow right arrow on GIF items, add GIF save branch |
| `Sources/Models/ClipboardRecord.swift` | Edit | Add `updateGifData()` method |

## References

- Brainstorm: `docs/brainstorms/2026-02-17-gif-editing-brainstorm.md`
- Text editing pattern: `Sources/Views/ClipboardPanelView.swift:142-148, 294-335`
- EditableTextView NSViewRepresentable: `Sources/Views/EditableTextView.swift`
- Existing GIF metadata extraction: `Sources/Models/ClipboardRecord.swift:121-137`
- updatePlainText pattern: `Sources/Models/ClipboardRecord.swift:97-115`
- Apple docs: [CGImageSource](https://developer.apple.com/documentation/imageio/cgimagesource)
- Apple docs: [CGImageDestination](https://developer.apple.com/documentation/imageio/cgimagedestination)
