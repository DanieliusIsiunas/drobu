---
title: "feat: Terminal text cleanup for clean Markdown pasting"
type: feat
date: 2026-02-20
brainstorm: docs/brainstorms/2026-02-20-terminal-text-cleanup-brainstorm.md
---

# feat: Terminal Text Cleanup

## Overview

Add a keyboard-triggered text cleanup feature that reformats clipboard text into clean Markdown. When editing a text clip with the cursor at position 0, pressing arrow up transforms the text — reflowing hard-wrapped prose, fencing code blocks, and normalizing structure. Additionally, strip ANSI escape sequences at capture time so color codes never enter the database.

## Problem Statement

Text copied from terminals contains hard line wraps at 80/120 character widths, mixed code and prose without boundaries, and ANSI color escape sequences. Pasting into Jira, Slack, MatterMost, or GitHub produces broken formatting — sentences split mid-line, code blocks not fenced, and invisible escape characters corrupting output.

## Proposed Solution

### User Flow

1. Select any text clip in the panel
2. Press right arrow to enter edit mode (cursor starts at position 0)
3. Press arrow up — cleanup transforms text into clean Markdown
4. Review the result, optionally make manual tweaks
5. Cmd+Return to save (replaces original) or Escape to discard

### Key Design Decisions

- **Available for ALL text clips** — no source app gating or bundle ID matching
- **Keyboard-only trigger** — arrow up at cursor position 0 in edit mode, no button
- **Markdown output only** — no mode picker, single transform function
- **Replace on save** — existing edit-mode save/discard behavior, no schema changes
- **ANSI stripping at capture** — applied in ClipboardMonitor for all text, not during cleanup
- **Pure function** — `TerminalTextCleaner.clean(_:) -> String`, stateless and testable

## Technical Approach

### Phase 1: ANSI Stripping at Capture

**File:** `Sources/Services/ClipboardMonitor.swift`

Add ANSI escape sequence stripping in `extractRecord(from:)` between text trimming (line 133) and hash calculation (line 137). This ensures no ANSI codes ever reach the database.

**Insertion point** — after line 133 (`let trimmed = ...`), before line 135 (`guard trimmed.utf8.count ...`):

```swift
// Strip ANSI escape sequences (terminal color codes, cursor control, etc.)
let cleaned = trimmed.replacingOccurrences(
    of: "\\x1B(?:\\[[0-9;]*[a-zA-Z]|\\][^\u{07}]*(?:\u{07}|\\x1B\\\\))",
    with: "",
    options: .regularExpression
)
```

Then use `cleaned` instead of `trimmed` for the rest of the method (empty check, size check, hash, record creation).

**ANSI patterns to strip:**
- CSI sequences: `\x1B[...m` (colors, styles), `\x1B[...H` (cursor), `\x1B[...J` (erase)
- OSC sequences: `\x1B]...BEL` or `\x1B]...\x1B\\` (title, hyperlinks)

### Phase 2: TerminalTextCleaner Service

**New file:** `Sources/Services/TerminalTextCleaner.swift`

Follow `GIFFrameEngine` pattern — `enum` with static methods, pure functions, no state.

```swift
enum TerminalTextCleaner {
    static func clean(_ text: String) -> String
}
```

**Block parsing pipeline:**

1. Split text into lines
2. Classify each line → `LineKind` (blank, heading, list, code, prose)
3. Group consecutive same-kind lines into `TextBlock` arrays
4. Process each block (reflow prose, preserve code/lists/headings)
5. Render as clean Markdown

**Line classification heuristics:**

| Pattern | Classification |
|---------|---------------|
| Empty / whitespace-only | `.blank` |
| Starts with `# ` (1-6 `#` chars) | `.heading` |
| Starts with `- `, `* `, or `N. ` (with optional indent) | `.list` |
| Indented 4+ spaces or starts with tab | `.code` |
| Contains syntax markers: `{ } => \| && \|\| () [];` and not a prose sentence | `.code` |
| Everything else | `.prose` |

**Prose reflow logic:**

1. Detect "terminal width" — find the mode of line lengths among lines > 60 chars
2. Lines within 5 chars of this width that don't end with `.?!:` are hard-wrap candidates
3. Join candidates with a space to form flowing paragraphs
4. Preserve blank-line paragraph breaks

**Markdown rendering:**

- Prose blocks: reflowed paragraphs separated by blank lines
- Code blocks: wrapped in ` ``` ` fences
- List blocks: preserved with normalized `-` markers
- Headings: preserved with blank lines before/after
- Maximum 1 consecutive blank line between blocks

### Phase 3: Keyboard Trigger in EditableTextView

**File:** `Sources/Views/EditableTextView.swift`

Add an `onCleanup` callback and intercept arrow up in `EditableNSTextView.keyDown(with:)`.

**Why arrow up at position 0 is safe to intercept:** When the cursor is at position 0 (start of document) with no selection, pressing arrow up in NSTextView does nothing — you're already at the top. Intercepting it creates no conflict with standard text editing.

**Changes to `EditableNSTextView` (line 6):**

```swift
fileprivate final class EditableNSTextView: NSTextView {
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onCleanup: (() -> Void)?    // NEW

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Return → save
        if event.keyCode == 36 && flags.contains(.command) {
            onSave?()
            return
        }

        // Arrow up at position 0 with no selection → cleanup          // NEW
        if event.keyCode == 126                                        // NEW
            && flags.isEmpty                                           // NEW
            && selectedRange().location == 0                           // NEW
            && selectedRange().length == 0 {                           // NEW
            onCleanup?()                                               // NEW
            return                                                     // NEW
        }                                                              // NEW

        super.keyDown(with: event)
    }
}
```

**Changes to `EditableTextView` struct (line 25):**

Add `var onCleanup: (() -> Void)?` property alongside existing `onSave` and `onDiscard`.

Thread it through in `makeNSView` (line 58) and `updateNSView` (line 81):

```swift
textView.onCleanup = onCleanup
```

### Phase 4: Wiring Through View Hierarchy

**File:** `Sources/Views/PreviewPanel.swift`

Add `var onCleanup: (() -> Void)?` property (line 9, alongside other callbacks).

Pass to `EditableTextView` in `textPreview(for:)` (line 47):

```swift
EditableTextView(
    text: $editingText,
    onSave: onSave,
    onDiscard: onDiscard,
    onCleanup: onCleanup       // NEW
)
```

**File:** `Sources/Views/ClipboardPanelView.swift`

Add cleanup method and wire callback to PreviewPanel (line 94):

```swift
PreviewPanel(
    item: previewItem,
    selectionCount: selectedItems.count,
    isEditing: $isEditing,
    editingText: $editingText,
    onSave: { saveEdit() },
    onDiscard: { discardEdit() },
    onGifSave: { trimmedData in saveGifTrim(data: trimmedData) },
    onCleanup: { cleanupText() }     // NEW
)
```

New method near `enterEditMode()`:

```swift
private func cleanupText() {
    let cleaned = TerminalTextCleaner.clean(editingText)
    guard !cleaned.isEmpty, cleaned != editingText else { return }
    editingText = cleaned
}
```

**Behavior notes:**
- Guard prevents replacing with empty string (data safety)
- Guard prevents no-op replacement (idempotency)
- `originalText` is NOT updated — Escape still discards to the pre-cleanup original
- Cursor stays at position 0 (SwiftUI binding update recreates text view)

## Acceptance Criteria

### Core Functionality
- [x] Arrow up at cursor position 0 in edit mode triggers text cleanup
- [x] Arrow up at any other cursor position behaves normally (moves cursor up)
- [x] Arrow up with text selection does NOT trigger cleanup (standard selection behavior)
- [x] Cleanup produces clean Markdown output
- [x] Escape after cleanup restores original pre-cleanup text
- [x] Cmd+Return after cleanup saves the cleaned version (replaces original)
- [x] Cleanup available for ALL text clips regardless of source app

### ANSI Stripping (Capture Time)
- [x] ANSI CSI sequences stripped from text on capture (`\x1B[...m`, etc.)
- [x] ANSI OSC sequences stripped on capture (`\x1B]...\x07`)
- [x] Stripping applied before hash calculation (no ANSI in contentHash)
- [x] Non-ANSI text unaffected by stripping

### Transformation Quality — Prose
- [x] Hard-wrapped prose lines joined into flowing paragraphs
- [x] Paragraph breaks (blank lines) preserved
- [x] Lines not near terminal width left unchanged
- [x] Lines ending with sentence punctuation (`.?!:`) not joined to next line

### Transformation Quality — Code
- [x] Indented blocks (4+ spaces/tab) wrapped in ``` fences
- [x] Lines with code syntax markers detected as code
- [x] Code content preserved exactly (no reflow, no modification)

### Transformation Quality — Structure
- [x] Headings (`#`) have blank lines before/after
- [x] Bullet lists preserved with normalized markers
- [x] Excessive blank lines collapsed (max 1 between blocks)
- [x] Already-clean Markdown remains stable (idempotent)

### Edge Cases
- [x] Single-line text: cleanup is no-op (guard catches `cleaned == editingText`)
- [x] Empty/whitespace-only text: cleanup is no-op (guard catches empty)
- [x] Very long text (near 1MB): completes without UI freeze
- [x] Text with only code: entire content fenced as code block
- [x] Text with only prose: reflowed without any fences

## Files Changed

| File | Change |
|------|--------|
| `Sources/Services/TerminalTextCleaner.swift` | **NEW** — Pure cleanup function |
| `Sources/Services/ClipboardMonitor.swift` | Add ANSI stripping at line 133 |
| `Sources/Views/EditableTextView.swift` | Add `onCleanup` callback, arrow up intercept |
| `Sources/Views/PreviewPanel.swift` | Thread `onCleanup` to EditableTextView |
| `Sources/Views/ClipboardPanelView.swift` | Add `cleanupText()`, wire `onCleanup` |

## Known Limitations (v1)

- **No undo beyond Escape** — cleanup replaces `editingText` but `originalText` preserved for discard. No Cmd+Z undo of cleanup specifically (NSTextView undo manager not used for programmatic replacement)
- **CJK/wide characters** — line-width heuristic uses character count, not display width
- **No plain text mode** — Markdown only
- **Not discoverable** — pure keyboard gesture, no visual hint
- **Code language detection** — fenced blocks use bare ``` without language annotation

## References

- Brainstorm: `docs/brainstorms/2026-02-20-terminal-text-cleanup-brainstorm.md`
- Edit mode: `Sources/Views/ClipboardPanelView.swift:300-306`
- EditableTextView: `Sources/Views/EditableTextView.swift:6-21`
- PreviewPanel text: `Sources/Views/PreviewPanel.swift:45-61`
- ClipboardMonitor text capture: `Sources/Services/ClipboardMonitor.swift:131-147`
- Service pattern reference: `Sources/Services/GIFFrameEngine.swift` (enum with static methods)
