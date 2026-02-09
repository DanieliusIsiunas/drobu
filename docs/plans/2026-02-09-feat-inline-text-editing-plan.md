---
title: "feat: Add inline text editing to preview panel"
type: feat
date: 2026-02-09
---

# feat: Add inline text editing to preview panel

## Overview

Add an edit mode to the right-side preview panel so users can quickly fix typos or tweak copied text before pasting — without leaving the clipboard manager.

## Interaction Flow

1. **Open panel** — list on left, read-only preview on right (unchanged)
2. **Right arrow** — enters edit mode for text items only (no-op for images or multi-selection)
3. **Edit freely** — full native macOS text editing (arrow keys, selection, undo/redo, spell check)
4. **Cmd+Return** — save edits & return focus to list
5. **Escape** — discard edits & return focus to list
6. **Panel closes during edit** — auto-save (edits preserved)

## Technical Approach

### Phase 1: EditableTextView (NSViewRepresentable)

Create `Sources/Views/EditableTextView.swift` — an NSTextView wrapper.

```
EditableTextView.swift
├── EditableTextView: NSViewRepresentable
│   ├── @Binding var text: String
│   ├── var isEditable: Bool
│   ├── var onSave: (() -> Void)?      // Cmd+Return
│   ├── var onDiscard: (() -> Void)?   // Escape
│   └── Coordinator: NSObject, NSTextViewDelegate
│       ├── textDidChange(_:)          // sync text binding + live word/char count
│       ├── textView(_:doCommandBy:)   // intercept Cmd+Return & Escape
│       └── manages NSUndoManager clearing on mode entry
├── makeNSView: create scrollable NSTextView with monospaced font
├── updateNSView: sync text & editable state, manage first responder
└── styling: transparent background, matching current preview font
```

**Key details:**
- Use `NSScrollView` + `NSTextView` (not bare NSTextView) for proper scrolling
- Match current font: `.system(.body, design: .monospaced)`
- Transparent background to blend with `NSVisualEffectView`
- `textView(_:doCommandBy:)` intercepts `insertNewline:` when Cmd is held → triggers save
- `textView(_:doCommandBy:)` intercepts `cancelOperation:` → triggers discard
- Clear `undoManager` each time `isEditable` transitions to `true`

Reference pattern: `Sources/Views/HotkeyRecorderView.swift:155-170`

### Phase 2: PreviewPanel edit mode

Modify `Sources/Views/PreviewPanel.swift` to support both modes.

Current (line 35-43):
```swift
// Read-only Text in ScrollView
Text(item.plainText ?? "")
    .font(.system(.body, design: .monospaced))
    .textSelection(.enabled)
```

Replace with:
```swift
EditableTextView(
    text: $editingText,
    isEditable: isEditing,
    onSave: onSave,
    onDiscard: onDiscard
)
```

**New props for PreviewPanel:**
- `@Binding var isEditing: Bool`
- `@Binding var editingText: String`
- `var onSave: (() -> Void)?`
- `var onDiscard: (() -> Void)?`

**Visual indicator:** When `isEditing`, show a 1pt `Color.accentColor` border around the text area with `cornerRadius(4)`. Instant transition (no animation).

**Metadata bar:** Word/char counts update live from `editingText` during editing.

### Phase 3: State management in ClipboardPanelView

Modify `Sources/Views/ClipboardPanelView.swift` to orchestrate edit mode.

**New state:**
```swift
@State private var isEditing = false
@State private var editingText = ""
@State private var originalText = ""  // for discard
```

**Keyboard handling changes (line 99-163):**

The Right arrow key enters edit mode:
```swift
case .rightArrow:
    guard !items.isEmpty,
          !hasMultiSelection,
          items[cursor].kind == ClipboardRecord.kindText,
          items[cursor].plainText != nil else { return .handled }
    enterEditMode()
    return .handled
```

When `isEditing` is true, the `.onKeyPress` handler returns `.ignored` for ALL keys — letting the NSTextView handle everything via the AppKit responder chain. This is the critical suppression mechanism.

```swift
.onKeyPress(phases: [.down, .repeat]) { press in
    if isEditing { return .ignored }
    // ... existing switch statement
}
```

**Important:** Also suppress the `Cmd+1-9` handler when editing:
```swift
.onKeyPress(characters: ...) { press in
    guard !isEditing else { return .ignored }
    // ... existing logic
}
```

**Enter edit mode:**
```swift
private func enterEditMode() {
    let item = items[cursor]
    editingText = item.plainText ?? ""
    originalText = editingText
    isEditing = true
}
```

**Save action:**
```swift
private func saveEdit() {
    guard isEditing else { return }
    isEditing = false

    let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)

    // Skip save if unchanged
    guard trimmed != originalText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

    // Reject empty text — revert silently
    guard !trimmed.isEmpty else { return }

    let item = items[cursor]
    guard let itemId = item.id else { return }

    Task.detached {
        try? await database.pool.write { db in
            ClipboardRecord.updatePlainText(id: itemId, newText: trimmed, in: db)
        }
    }

    // Cursor will move to 0 when ValueObservation fires (item moves to top)
    anchor = 0
    cursor = 0
}
```

**Discard action:**
```swift
private func discardEdit() {
    isEditing = false
    editingText = originalText
}
```

**Panel close during edit — auto-save:**

In `onDisappear`, save if editing:
```swift
.onDisappear {
    if isEditing { saveEdit() }
    // ... existing cleanup
}
```

### Phase 4: Database update method

Add to `Sources/Models/ClipboardRecord.swift`:

```swift
/// Update text content, recalculate hash, and move to top.
static func updatePlainText(id: Int64, newText: String, in db: Database) throws {
    let newHash = sha256(newText)

    // Delete any existing item with the same hash (dedup)
    try db.execute(
        sql: "DELETE FROM clipboardItem WHERE contentHash = ? AND id != ?",
        arguments: [newHash, id]
    )

    // Update the record in place
    try db.execute(
        sql: """
            UPDATE clipboardItem
            SET plainText = ?, contentHash = ?, createdAt = ?
            WHERE id = ?
            """,
        arguments: [newText, newHash, Date(), id]
    )
}

private static func sha256(_ text: String) -> String {
    import CryptoKit
    let data = text.data(using: .utf8)!
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
```

**Note:** The `sha256` helper already exists in `ClipboardMonitor.swift:131-133`. Extract it to a shared location (e.g., a static method on `ClipboardRecord` or a top-level utility) to avoid duplication.

FTS5 index auto-syncs via triggers set up in `AppDatabase.swift:69` (`synchronize(withTable:)`). No manual FTS update needed.

### Phase 5: Focus management (AppKit ↔ SwiftUI bridge)

**Entering edit mode:**
- `EditableTextView.updateNSView` detects `isEditable` becoming `true`
- Calls `nsView.window?.makeFirstResponder(nsView)` to give NSTextView keyboard focus
- Sets cursor position to beginning: `nsView.setSelectedRange(NSRange(location: 0, length: 0))`

**Exiting edit mode:**
- `EditableTextView.updateNSView` detects `isEditable` becoming `false`
- Calls `nsView.window?.makeFirstResponder(nsView.window?.contentView)` to return focus to the NSHostingView
- This re-enables SwiftUI's `.onKeyPress` handlers

**Key assumption to verify:** When NSTextView is first responder, SwiftUI's `.onKeyPress` on parent views should NOT fire because events are consumed at the AppKit responder chain level. The `if isEditing { return .ignored }` guard is a safety net.

## Acceptance Criteria

- [ ] Right arrow enters edit mode for single-selected text items
- [ ] Right arrow is no-op for image items and multi-selection
- [ ] Full native text editing works (typing, selection, undo/redo, spell check)
- [ ] Cmd+Return saves edits and returns focus to list
- [ ] Escape discards edits and returns focus to list
- [ ] Panel close during edit auto-saves
- [ ] Edited item moves to top of list (createdAt updated)
- [ ] Cursor follows edited item to index 0 after save
- [ ] Content hash recalculated on save (dedup works correctly)
- [ ] FTS5 index updated (edited text is searchable)
- [ ] No-op save when text is unchanged (no timestamp bump)
- [ ] Empty text rejected (reverts silently)
- [ ] Duplicate hash handled (other item deleted, edit preserved)
- [ ] Accent border visible during edit mode
- [ ] Word/char count updates live during editing
- [ ] List navigation (up/down/delete/Cmd+1-9) suppressed during editing
- [ ] Undo stack cleared on each edit session entry

## Edge Cases

| Case | Behavior |
|---|---|
| Right arrow on image item | No-op |
| Right arrow with multi-selection | No-op |
| Edit to empty string | Revert to original (reject save) |
| Edit to match another item's hash | Delete the other item, keep edited one |
| No changes made, Cmd+Return | Skip save, just exit edit mode |
| Panel dismissed during edit | Auto-save |
| External clipboard change during edit | List updates via ValueObservation; editing continues unaffected (bound to `editingText` state, not `items` array) |
| Very large text | NSTextView handles efficiently; async DB write |

## Files to Modify

| File | Change |
|---|---|
| `Sources/Views/EditableTextView.swift` | **New** — NSViewRepresentable wrapping NSTextView |
| `Sources/Views/PreviewPanel.swift` | Replace `Text()` with `EditableTextView`, add edit mode props |
| `Sources/Views/ClipboardPanelView.swift` | Add `isEditing` state, Right arrow handler, save/discard actions, keyboard suppression |
| `Sources/Models/ClipboardRecord.swift` | Add `updatePlainText()` static method |
| `Sources/Services/ClipboardMonitor.swift` | Extract `sha256()` to shared location (or duplicate in ClipboardRecord) |

## References

- Brainstorm: `docs/brainstorms/2026-02-09-inline-text-editing-brainstorm.md`
- NSViewRepresentable pattern: `Sources/Views/HotkeyRecorderView.swift:155-170`
- Current preview rendering: `Sources/Views/PreviewPanel.swift:35-43`
- Keyboard handler: `Sources/Views/ClipboardPanelView.swift:99-163`
- FTS5 auto-sync: `Sources/Database/AppDatabase.swift:69`
- Content hash: `Sources/Services/ClipboardMonitor.swift:131-133`
- Focus lessons: MEMORY.md — NSPanel lifecycle, WeakFloatingPanel, onAppear unreliability
