---
title: Multi-Select & Sequential Paste
type: feat
date: 2026-02-09
---

# Multi-Select & Sequential Paste

## Context

Pasting multiple clipboard items (especially images) into apps like Claude Code CLI requires selecting and pasting them one by one. This feature adds Shift+Arrow range selection to the clipboard history panel, with sequential auto-paste that writes each item to the pasteboard and fires Cmd+V individually. This approach works universally because most apps (including Claude Code) only read one pasteboard item at a time.

Brainstorm: `docs/brainstorms/2026-02-09-multi-select-paste-brainstorm.md`

## Proposed Solution

### 1. Selection State Model

**File:** `Sources/Views/ClipboardPanelView.swift`

Replace `@State private var selectedIndex = 0` with an anchor/cursor model:

```swift
@State private var anchor = 0    // where Shift-select started
@State private var cursor = 0    // current keyboard position (follows arrows)
```

Computed properties:

```swift
private var selectionRange: ClosedRange<Int> {
    min(anchor, cursor)...max(anchor, cursor)
}

private var hasMultiSelection: Bool {
    anchor != cursor
}

private var selectedItems: [ClipboardRecord] {
    guard !items.isEmpty else { return [] }
    let clamped = selectionRange.clamped(to: 0...(items.count - 1))
    return Array(items[clamped])
}

// For PreviewPanel — show cursor item in single-select, summary in multi
private var previewItem: ClipboardRecord? {
    guard cursor < items.count else { return nil }
    return items[cursor]
}
```

### 2. Keyboard Navigation

**File:** `Sources/Views/ClipboardPanelView.swift`

Replace the separate `.onKeyPress(.downArrow)` and `.onKeyPress(.upArrow)` handlers with a single catch-all handler that can detect modifiers:

```swift
.onKeyPress(phases: [.down, .repeat]) { press in
    switch press.key {
    case .downArrow:
        if press.modifiers.contains(.shift) {
            // Extend selection downward (clamp, no wrap)
            if cursor < items.count - 1 { cursor += 1 }
        } else {
            // Collapse to bottom of range + move down, or just move
            let newIndex = hasMultiSelection
                ? min(max(anchor, cursor), items.count - 1)
                : (cursor + 1) % items.count
            anchor = newIndex
            cursor = newIndex
        }
        return .handled

    case .upArrow:
        if press.modifiers.contains(.shift) {
            // Extend selection upward (clamp, no wrap)
            if cursor > 0 { cursor -= 1 }
        } else {
            let newIndex = hasMultiSelection
                ? min(anchor, cursor)
                : (cursor - 1 + items.count) % items.count
            anchor = newIndex
            cursor = newIndex
        }
        return .handled

    case .return:
        pasteSelected()
        return .handled

    case .escape:
        if hasMultiSelection {
            cursor = anchor  // collapse to anchor
        } else if !searchText.isEmpty {
            searchText = ""
        } else {
            panel?.close()
        }
        return .handled

    case .deleteForward:
        deleteSelected()
        return .handled

    default:
        return .ignored
    }
}
```

Keep the Cmd+1-9 handler as a separate `.onKeyPress(characters:phases:)` — it already detects modifiers via `press.modifiers == .command`. Those shortcuts remain single-item paste (unchanged).

Update the scroll tracking from `onChange(of: selectedIndex)` to `onChange(of: cursor)`:

```swift
.onChange(of: cursor) { _, newValue in
    withAnimation(.easeOut(duration: 0.1)) {
        proxy.scrollTo(newValue, anchor: .center)
    }
}
```

### 3. Item List & Row View Updates

**File:** `Sources/Views/ClipboardPanelView.swift` — itemList

Change `isSelected` to check range membership:

```swift
ClipboardRowView(
    item: item,
    isSelected: selectionRange.contains(index),
    shortcutIndex: index < 9 ? index : nil
)
```

Click behavior stays as-is (single-item paste on click). Multi-select is keyboard-only in v1.

**File:** `Sources/Views/ClipboardRowView.swift`

No changes needed — `isSelected: Bool` continues to work. When multiple rows have `isSelected = true`, they all get the accent highlight. The return arrow icon shows on whichever is the cursor (or we can keep it simple and show it on all selected rows — the user knows Enter pastes them all).

Actually, refine the shortcut label: show the return arrow only on the **cursor** row when multi-selecting. Add a new parameter:

```swift
struct ClipboardRowView: View {
    let item: ClipboardRecord
    let isSelected: Bool
    let isCursor: Bool        // NEW: true for the keyboard-focus row
    let shortcutIndex: Int?
```

Update `shortcutLabel`:
- If `isCursor` → show return arrow
- Else if `isSelected` (multi) → show nothing (no shortcut label, just highlight)
- Else if `shortcutIndex` → show Cmd+N
- Else → nothing

### 4. Preview Panel for Multi-Select

**File:** `Sources/Views/PreviewPanel.swift`

Add an overload or change the interface to accept optional multi-select info:

```swift
struct PreviewPanel: View {
    let item: ClipboardRecord?
    let selectionCount: Int      // NEW: 1 for single, N for multi
```

When `selectionCount > 1`, show a summary instead of a single item preview:

```
"N items selected"
"(X text, Y images)"
```

The parent passes `selectionCount: selectedItems.count`.

### 5. Sequential Paste Logic

**File:** `Sources/Views/FloatingPanel.swift`

Add a new method `pasteItems(_:)` alongside the existing `pasteItem(_:)`:

```swift
func pasteItems(_ records: [ClipboardRecord]) {
    guard !records.isEmpty else { return }

    // Single item — use existing fast path
    if records.count == 1 {
        pasteItem(records[0])
        return
    }

    // Suppress self-capture for all upcoming pasteboard writes
    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
        let imageCount = records.filter { $0.kind == ClipboardRecord.kindImage }.count
        let textItems = records.filter { $0.kind == ClipboardRecord.kindText }
        let suppressCount = (textItems.isEmpty ? 0 : 1) + imageCount
        appDelegate.monitor?.suppressChanges(count: suppressCount)
    }

    // Close panel first (instant)
    close()

    guard AXIsProcessTrusted() else {
        // Without accessibility, concatenate text and put on pasteboard (best effort)
        // Images cannot be multi-pasted without accessibility
        let textItems = records.filter { $0.kind == ClipboardRecord.kindText }
        if !textItems.isEmpty {
            let combined = textItems.compactMap(\.plainText).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(combined, forType: .string)
        }
        showCopiedNotification()
        return
    }

    // Build paste operations: text concatenated first, then images individually
    var operations: [PasteOperation] = []

    let textItems = records.filter { $0.kind == ClipboardRecord.kindText }
    let imageItems = records.filter { $0.kind == ClipboardRecord.kindImage }

    if !textItems.isEmpty {
        let combined = textItems.compactMap(\.plainText).joined(separator: "\n")
        operations.append(.text(combined))
    }
    for img in imageItems {
        if let data = img.imageData {
            operations.append(.image(data))
        }
    }

    // Execute sequentially with delay
    executePasteSequence(operations, index: 0)
}

private enum PasteOperation {
    case text(String)
    case image(Data)
}

private func executePasteSequence(_ ops: [PasteOperation], index: Int) {
    guard index < ops.count else { return }

    let pb = NSPasteboard.general
    pb.clearContents()

    switch ops[index] {
    case .text(let str):
        pb.setString(str, forType: .string)
    case .image(let data):
        pb.setData(data, forType: .tiff)
    }

    firePaste()

    // Schedule next operation after delay
    if index + 1 < ops.count {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.executePasteSequence(ops, index: index + 1)
        }
    }
}
```

The 100ms delay is a starting point — will need testing with Claude Code CLI.

### 6. Self-Capture Suppression for N Pastes

**File:** `Sources/Services/ClipboardMonitor.swift`

Replace the boolean `isSuppressed` with a counter:

```swift
private var suppressCount = 0

func suppressNextChange() {
    suppressCount = 1            // backwards compatible
}

func suppressChanges(count: Int) {
    suppressCount = count
}

private func checkForChanges() {
    guard pasteboard.changeCount != lastChangeCount else { return }
    lastChangeCount = pasteboard.changeCount

    if suppressCount > 0 {
        suppressCount -= 1
        return
    }
    // ... rest unchanged
}
```

### 7. Multi-Delete

**File:** `Sources/Views/ClipboardPanelView.swift`

Update `deleteSelected()` to handle multiple items:

```swift
private func deleteSelected() {
    let toDelete = selectedItems.compactMap(\.id)
    guard !toDelete.isEmpty else { return }

    // Move selection to item after the deleted range
    let afterIndex = max(anchor, cursor) + 1
    let newIndex = afterIndex < items.count ? afterIndex - toDelete.count : max(0, min(anchor, cursor) - 1)

    Task.detached {
        try? await database.pool.write { db in
            for id in toDelete {
                try ClipboardRecord.deleteById(id, in: db)
            }
        }
    }

    // Reset to single selection
    anchor = max(0, min(newIndex, items.count - toDelete.count - 1))
    cursor = anchor
}
```

### 8. Database Observation — Selection Stability

**File:** `Sources/Views/ClipboardPanelView.swift`

When `items` updates via `ValueObservation.onChange`, clamp both `anchor` and `cursor`:

```swift
observation = ValueObservation.tracking { db in
    try ClipboardRecord.search(query: query, in: db)
}
.start(in: pool, onError: { _ in }, onChange: { [self] newItems in
    items = newItems
    let maxIdx = max(0, newItems.count - 1)
    if anchor > maxIdx { anchor = maxIdx }
    if cursor > maxIdx { cursor = maxIdx }
})
```

Also reset both on search text change:

```swift
.onChange(of: searchText) { _, _ in
    anchor = 0
    cursor = 0
    startObservation()
}
```

And reset both in `onDisappear`:

```swift
.onDisappear {
    observation?.cancel()
    observation = nil
    searchText = ""
    anchor = 0
    cursor = 0
}
```

## Files to Modify

| File | Changes |
|---|---|
| `Sources/Views/ClipboardPanelView.swift` | Replace `selectedIndex` with `anchor`/`cursor`, rewrite keyboard handlers, update row binding, update delete, update observation clamping |
| `Sources/Views/FloatingPanel.swift` | Add `pasteItems(_:)`, `PasteOperation` enum, `executePasteSequence()` |
| `Sources/Views/ClipboardRowView.swift` | Add `isCursor: Bool` parameter, update shortcut label logic |
| `Sources/Views/PreviewPanel.swift` | Add `selectionCount: Int`, show multi-select summary |
| `Sources/Services/ClipboardMonitor.swift` | Replace `isSuppressed: Bool` with `suppressCount: Int`, add `suppressChanges(count:)` |

## Design Decisions Summary

1. **Anchor/cursor model** over `Set<Int>` — simpler for contiguous-only selection, O(1) range check
2. **SwiftUI `onKeyPress(phases:action:)`** for Shift detection — `KeyPress.modifiers` includes `.shift` (confirmed via Apple docs). No need to drop to NSEvent
3. **Clamp at boundaries** for Shift+Arrow (no wrapping). Plain arrows keep wrapping for single-select
4. **Plain arrow collapse**: Down collapses to bottom of range, Up to top (matches Finder)
5. **Escape collapse**: returns to anchor
6. **Text concatenation**: `\n` separator, no trimming
7. **Mixed content order**: all text concatenated first (single paste), then images individually in list order. This reorders vs. the visual list, but matches the brainstorm decision
8. **Click**: unchanged (immediate single-item paste). Multi-select is keyboard-only in v1
9. **100ms inter-paste delay**: starting point, tune empirically with Claude Code CLI
10. **No paste loop cancellation** in v1 — the loop is very fast (N * 100ms). Revisit if issues arise

## Acceptance Criteria

- [x] Shift+Down/Up extends selection as a contiguous highlighted range
- [x] Plain Down/Up collapses multi-selection and moves single cursor
- [x] Escape collapses multi-selection to anchor without closing panel
- [x] Enter with multi-selection: text items concatenated (newline-separated) into one paste, images pasted individually with delay
- [x] Self-capture prevention works for N sequential pastes (no duplicate DB entries)
- [x] Delete removes all selected items
- [x] Preview panel shows "N items selected" during multi-select
- [x] Cmd+1-9 still works as single-item quick paste
- [x] Single-item selection works identically to before (no regression)

## Verification

1. Build and run: `bash build.sh 2>&1 && pkill -f "ClipboardHistory" && sleep 0.5 && open .build/ClipboardHistory.app`
2. Copy 4 different text snippets, open panel, Shift+Down to select all 4, press Enter. Verify all text appears concatenated in the target app.
3. Take 4 screenshots, open panel, Shift+Down to select all 4, press Enter. Verify all 4 images paste sequentially into Claude Code CLI.
4. Select a mix of text + images, press Enter. Verify text pastes first (concatenated), then images individually.
5. Select 3 items, press Delete. Verify all 3 are removed and selection moves to a valid position.
6. Verify no duplicate entries appear in clipboard history after multi-paste (self-capture suppression).
7. Verify plain arrow keys, Escape, and Cmd+1-9 still work correctly.
