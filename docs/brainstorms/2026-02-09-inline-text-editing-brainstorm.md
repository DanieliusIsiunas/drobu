# Inline Text Editing in Preview Panel

**Date:** 2026-02-09
**Status:** Ready for planning

## What We're Building

The right-side preview panel gains an edit mode for text items. Users can quickly fix typos or tweak copied text before pasting — without leaving the clipboard manager.

### Interaction Flow

1. **Open panel** — list on left, read-only preview on right (unchanged)
2. **Right arrow** — enters edit mode: text becomes editable, cursor at beginning of text
3. **Edit freely** — full native text editing (arrow keys, selection, undo/redo, etc.)
4. **Cmd+Shift+Left arrow** — save edits & return focus to list
5. **Escape** — discard edits & return focus to list (text reverts)

### Visual Indicator

- Subtle accent-colored border around the text area when in edit mode
- Blinking text cursor also signals edit state

## Why This Approach

**NSTextView via NSViewRepresentable** over SwiftUI TextEditor because:

- Native macOS undo/redo, spell check, find/replace — all free
- Proper vibrancy and font rendering matching the HUD panel
- Better performance with large text blocks
- The app already bridges AppKit (NSPanel, NSHostingView), so NSViewRepresentable is consistent

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Text items only (no image editing) | Keep first iteration simple |
| Enter edit mode | Right arrow key | Intuitive — move "into" the preview |
| Save & exit | Cmd+Return | No conflict with any text editing shortcut; widely understood as "submit/confirm" |
| Discard & exit | Escape | Standard cancel pattern |
| Cursor placement | Beginning of text | Simple and predictable |
| Save behavior | Auto-save on Cmd+Shift+Left | No confirmation dialog needed |
| Content hash | Recalculate on save | Deduplication works correctly against edited content |
| Edit indicator | Accent border on text area | Subtle but clear signal |
| Text rendering | NSTextView (NSViewRepresentable) | Native editing UX, undo stack, vibrancy |

## Implementation Notes

- `ClipboardRecord` needs an `updatePlainText()` method that also recalculates `contentHash`
- `PreviewPanel` switches between read-only NSTextView and editable NSTextView based on mode
- Focus management: entering edit mode must make NSTextView first responder; exiting must return focus to SwiftUI list
- FTS5 index must be updated when text changes (GRDB handles this if the record is updated properly)

## Resolved Questions

- **Timestamp on edit:** Move to top (update `createdAt` so edited item appears as most recent)
