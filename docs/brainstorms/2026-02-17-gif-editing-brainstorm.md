# GIF Editing (Phase 2) Brainstorm

**Date:** 2026-02-17
**Status:** Ready for planning
**Depends on:** Phase 1 (GIF Preview) — completed

## What We're Building

Inline GIF trimming within the clipboard panel. Select a GIF, press right arrow to enter trim mode, drag timeline handles to set start/end, preview plays only the selected range, Cmd+Return saves the trimmed GIF in place.

**Scope: Trim only.** Speed, reverse, crop deferred to future iterations.

## Why This Approach

- **Consistent with text editing UX** — same entry (right arrow), save (Cmd+Return), discard (Escape) pattern
- **iPhone video trim metaphor** — users already understand timeline scrubbers with drag handles
- **CGImageSource/CGImageDestination** — pure ImageIO, zero dependencies, already partially used for metadata extraction in Phase 1
- **Replace in place** — trimmed GIF overwrites original, moves to top (same as text edit behavior)

## Key Decisions

### Editing operations
- **Trim only** for MVP. Single, well-defined operation. Covers 80% of GIF editing needs.
- Speed, reverse, crop are natural follow-ups but not needed now.

### Enter/exit edit mode
- **Right arrow** enters trim mode (same as text edit)
- **Cmd+Return** saves trimmed GIF
- **Escape** discards changes, returns to preview mode
- Consistent with existing keyboard-driven UX

### Timeline scrubber UI
- Horizontal bar below GIF preview showing frame positions
- Draggable left/right handles for start/end trim points
- GIF preview plays **only the selected range** (loops within trim points)
- Like iPhone video trim — proven, intuitive UX

### Save behavior
- **Replace original in place** — trimmed GIF overwrites the DB record
- Moves to top of list (fresh createdAt, new contentHash)
- Same pattern as text editing — simple, no clutter
- Non-destructive undo not in scope (user can always re-copy the original)

### Technical approach
- **Edit mode switches renderer**: NSImageView (auto-play) → custom frame-by-frame player (Timer-driven CGImage display)
- **CGImageSource** extracts all frames + per-frame delays (already used for metadata)
- **Custom frame player** renders CGImages with a Timer, respecting frame delays, looping only within trim range
- **CGImageDestination** writes selected frame subset back as new GIF data
- **DB update** reuses existing `ClipboardRecord.updateGifData()` pattern (new method, similar to `updatePlainText()`)

### New components needed
1. **GIF Frame Engine** — extracts frames + delays from GIF data via CGImageSource, writes trimmed frames via CGImageDestination
2. **Frame Player View** — NSViewRepresentable that displays CGImages frame-by-frame with a Timer, supports playing a range
3. **Timeline Scrubber** — SwiftUI view with draggable start/end handles over a frame progress bar

## Open Questions (for planning)

- Should the scrubber show mini frame thumbnails or just a simple progress bar with handle positions?
- Frame player: use CALayer.contents for rendering individual frames, or draw into an NSImageView?
- Maximum frame count to handle in memory? (1000-frame GIFs at 20MB)
- Should we show a frame counter (e.g., "Frames 12-48 of 96") during trim?

## Competitive Reference

- **iOS Photos video trim** — the gold standard for timeline scrubber UX
- **Gifox editor** — GIF-specific trim with filmstrip thumbnail view
- Both use the same pattern: visual timeline, drag handles, live preview of selection

## Next Step

Run `/workflows:plan` to create implementation plan.
