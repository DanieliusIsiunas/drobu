---
title: "feat: Terminal text cleanup for pasting into Jira/MatterMost"
type: feat
date: 2026-02-20
brainstorm: docs/brainstorms/2026-02-20-terminal-text-cleanup-brainstorm.md
---

# feat: Terminal Text Cleanup

## Overview

Add a "Clean up" action in the preview panel that reformats terminal-sourced text clips for clean pasting into rich-text apps like Jira and MatterMost. Terminal text is detected via `sourceBundleId` matching known terminal emulators. Two output modes: Clean Markdown and Plain text.

## Problem Statement

Text copied from terminal apps contains hard line wraps at the terminal width (80/120 chars), mixed code and prose without clear boundaries, and raw Markdown artifacts. When pasted into Jira, MatterMost, or similar apps, the formatting breaks — sentences are split mid-line, code blocks aren't fenced, and structure is lost. Users must manually reformat every paste.

## Proposed Solution

### User Flow

1. User copies text from a terminal app
2. Opens clipboard panel, selects the item
3. Preview panel shows read-only text with a **"Clean up" button** (visible because `sourceBundleId` matches)
4. A **segmented picker** next to the button lets user choose: `Markdown` (default) or `Plain text`
5. User clicks "Clean up" (or presses **Cmd+L** keyboard shortcut)
6. App transforms the text and enters **edit mode** with the cleaned result pre-populated
7. User reviews, optionally tweaks, saves (**Cmd+Return**) or discards (**Escape**)
8. Saved version overwrites the original via existing `updatePlainText()` path

### Key Design Decisions

- **Detection:** `sourceBundleId` heuristic only — no content analysis for v1
- **Terminal list:** Hardcoded set of known terminal bundle IDs (not user-configurable in v1)
- **Trigger:** Manual button + keyboard shortcut (Cmd+L) — not auto-applied
- **Edit mode reuse:** Cleanup populates `editingText` with transformed text and sets `originalText` to the raw text, then enters standard edit mode. All existing save/discard/auto-save-on-close behavior applies
- **Output mode toggle:** Segmented picker next to the "Clean up" button, visible only in read-only state. Mode persisted in UserDefaults. Toggling during edit mode is not supported — user must discard first, toggle, then re-clean
- **No schema changes:** Transform on-the-fly into edit mode, save via existing `updatePlainText()`
- **Transformation is a pure function:** `TerminalTextCleaner.clean(_:mode:) -> String` — no side effects, testable in isolation

### Terminal Bundle IDs (Initial Set)

| App | Bundle ID |
|-----|-----------|
| Terminal.app | `com.apple.Terminal` |
| iTerm2 | `com.googlecode.iterm2` |
| Warp | `dev.warp.Warp-Stable` |
| Alacritty | `org.alacritty` |
| kitty | `net.kovidgoyal.kitty` |
| WezTerm | `com.github.wez.wezterm` |

**Excluded:** VS Code (`com.microsoft.VSCode`) and Cursor — these are editors with integrated terminals, but there's no way to distinguish terminal pane copies from editor copies. Including them would show the button on every code clip, which is noisy. Users can manually enter edit mode for these.

## Technical Approach

### New File: `Sources/Services/TerminalTextCleaner.swift`

Pure transformation logic — no UI, no database, no side effects.

```swift
// Sources/Services/TerminalTextCleaner.swift

enum CleanupMode: String, CaseIterable {
    case markdown = "Markdown"
    case plainText = "Plain text"
}

struct TerminalTextCleaner {

    /// Known terminal emulator bundle IDs
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    static func isTerminalSource(_ bundleId: String?) -> Bool {
        guard let id = bundleId else { return false }
        return terminalBundleIds.contains(id)
    }

    static func clean(_ text: String, mode: CleanupMode) -> String {
        var result = text
        result = stripANSIEscapes(result)
        result = normalizeWhitespace(result)

        // Parse into blocks (prose, code, list, blank)
        let blocks = parseBlocks(result)

        // Render based on mode
        switch mode {
        case .markdown:
            return renderMarkdown(blocks)
        case .plainText:
            return renderPlainText(blocks)
        }
    }

    // --- Internal methods ---

    /// Strip ANSI escape sequences (\x1B[...m, etc.)
    static func stripANSIEscapes(_ text: String) -> String { ... }

    /// Normalize trailing whitespace, collapse 3+ blank lines to 2
    static func normalizeWhitespace(_ text: String) -> String { ... }

    /// Parse text into typed blocks: prose, code, list, heading, blank
    static func parseBlocks(_ text: String) -> [TextBlock] { ... }

    /// Join hard-wrapped prose lines within a block
    static func reflowProse(_ lines: [String]) -> String { ... }

    /// Render blocks as clean Markdown
    static func renderMarkdown(_ blocks: [TextBlock]) -> String { ... }

    /// Render blocks as plain reflowed text
    static func renderPlainText(_ blocks: [TextBlock]) -> String { ... }
}
```

### Block Parsing Heuristics

Each line is classified, then consecutive lines of the same type form a block:

| Line Pattern | Classification | Rules |
|---|---|---|
| Blank line | `.blank` | Separates blocks |
| Starts with `#` + space | `.heading` | Preserve as-is |
| Starts with `- `, `* `, `1. ` (with optional leading spaces) | `.list` | Preserve structure, don't reflow |
| Indented 4+ spaces or starts with tab | `.code` | Preserve exactly |
| Contains `{`, `}`, `=>`, `\|`, `&&`, `\|\|`, `()`, `[];` patterns | `.code` | Syntax markers |
| Line length within 70-130 chars, doesn't end with `.?!:` | `.prose` (likely hard-wrapped) | Candidate for reflow |
| All other lines | `.prose` | Keep as-is if short |

**Prose reflow logic:**
- Detect "terminal width" from the text: find the most common line length among long lines (mode of lengths > 60)
- Lines within 5 chars of this width that don't end with sentence-ending punctuation are candidates for joining
- Join candidates into flowing paragraphs, preserving blank-line paragraph breaks

**Markdown mode rendering:**
- Prose blocks: reflowed paragraphs
- Code blocks: wrapped in ` ``` ` fences
- Lists: normalized markers (`-`), proper indentation
- Headings: ensure blank lines before/after
- Max 1 consecutive blank line between blocks

**Plain text mode rendering:**
- Prose blocks: reflowed paragraphs
- Code blocks: kept indented (no fences)
- Lists: kept as-is
- Headings: kept as-is (no Markdown `#` stripping — they're still useful as structure)
- Markdown emphasis (`**bold**`, `*italic*`) stripped

### Modified File: `Sources/Views/PreviewPanel.swift`

Add to the `PreviewPanel` struct:
- New callback: `var onCleanup: ((CleanupMode) -> Void)?`
- New property: `var showCleanupAction: Bool = false`
- New binding: `@Binding var cleanupMode: CleanupMode`
- A cleanup toolbar between the text preview and metadata bar, shown when `showCleanupAction && !isEditing`:
  - Segmented `Picker` for `CleanupMode`
  - "Clean up" `Button` (calls `onCleanup?(cleanupMode)`)
  - Keyboard hint label: "Cmd+L"

```swift
// In textPreview(for:), between the ScrollView and metadataBar:
if showCleanupAction && !isEditing {
    cleanupToolbar
}
```

### Modified File: `Sources/Views/ClipboardPanelView.swift`

Add:
- `@State private var cleanupMode: CleanupMode = .markdown` (persisted via `@AppStorage`)
- `@AppStorage("cleanupMode") private var storedCleanupMode: String = CleanupMode.markdown.rawValue`
- New method `cleanupTerminalText()`:

```swift
private func cleanupTerminalText() {
    guard let item = previewItem,
          item.kind == ClipboardRecord.kindText,
          let text = item.plainText else { return }

    let cleaned = TerminalTextCleaner.clean(text, mode: cleanupMode)
    editingText = cleaned
    originalText = text  // Raw text for discard
    editingItemId = item.id
    isEditing = true
}
```

- Wire `onCleanup` callback in `PreviewPanel` instantiation
- Add Cmd+L keyboard shortcut in `onKeyPress`:

```swift
case .init("l") where press.modifiers == .command:
    if showCleanupForCurrentItem && !isEditing {
        cleanupTerminalText()
        return .handled
    }
```

- Computed property `showCleanupForCurrentItem`:

```swift
private var showCleanupForCurrentItem: Bool {
    guard let item = previewItem,
          item.kind == ClipboardRecord.kindText else { return false }
    return TerminalTextCleaner.isTerminalSource(item.sourceBundleId)
}
```

### No Database Changes

Reuses existing `ClipboardRecord.updatePlainText(id:newText:in:)` via the standard `saveEdit()` flow. Hash recalculation and deduplication handled automatically.

## Acceptance Criteria

### Core Functionality
- [ ] "Clean up" button appears in preview panel for text items with terminal `sourceBundleId`
- [ ] Button is hidden for non-terminal sources, images, GIFs, and multi-selections
- [ ] Clicking "Clean up" transforms text and enters edit mode with cleaned result
- [ ] Cmd+L keyboard shortcut triggers cleanup (when not already editing)
- [ ] Segmented picker toggles between Markdown and Plain text modes
- [ ] Mode selection persisted in UserDefaults across sessions
- [ ] Cmd+Return saves cleaned text (existing edit flow)
- [ ] Escape discards and restores original raw text (existing discard flow)

### Transformation — Markdown Mode
- [ ] Hard-wrapped prose lines joined into flowing paragraphs
- [ ] Paragraph breaks (blank lines) preserved
- [ ] Indented/code-like sections wrapped in fenced code blocks
- [ ] Headings have blank lines before and after
- [ ] Bullet/numbered lists preserved with normalized markers
- [ ] ANSI escape sequences stripped
- [ ] Excessive blank lines collapsed (max 1 between blocks)

### Transformation — Plain Text Mode
- [ ] Hard-wrapped prose lines joined into flowing paragraphs
- [ ] Code blocks preserved with indentation (no fences)
- [ ] Markdown emphasis markers stripped (`**`, `*`, `` ` ``)
- [ ] ANSI escape sequences stripped

### Edge Cases
- [ ] Single-line text: no-op transformation (still enters edit mode with same text)
- [ ] Empty/whitespace-only text: no-op
- [ ] Already-clean text: idempotent (running cleanup twice produces same result)
- [ ] Items with `sourceBundleId = nil`: button not shown (expected for legacy items)

## Implementation Phases

### Phase 1: Transformation Engine
**Files:** New `Sources/Services/TerminalTextCleaner.swift`

Build and test the pure transformation function in isolation:
1. `isTerminalSource()` — bundle ID matching
2. `stripANSIEscapes()` — regex-based ANSI removal
3. `normalizeWhitespace()` — trailing whitespace, blank line collapsing
4. `parseBlocks()` — line classification and block grouping
5. `reflowProse()` — terminal-width detection and line joining
6. `renderMarkdown()` / `renderPlainText()` — mode-specific output

Test with representative samples:
- `man` page output (80-col prose)
- `git log --oneline` output (short lines, not hard-wrapped)
- `git diff` output (code with `+`/`-` prefixes)
- Compiler error messages (mixed paths and prose)
- Claude Code CLI output (Markdown with code blocks, prose paragraphs)
- Shell session transcript (`$` prompts + output)

### Phase 2: UI Integration
**Files:** `Sources/Views/PreviewPanel.swift`, `Sources/Views/ClipboardPanelView.swift`

1. Add `showCleanupAction` property and `onCleanup` callback to `PreviewPanel`
2. Build the cleanup toolbar (segmented picker + button)
3. Add `cleanupTerminalText()` method to `ClipboardPanelView`
4. Wire up the `onCleanup` callback
5. Add `@AppStorage` for mode persistence
6. Add Cmd+L keyboard shortcut

### Phase 3: Polish
1. Tune prose reflow heuristics based on real terminal output testing
2. Verify bundle IDs by copying from each target terminal app
3. Ensure idempotency (cleanup of already-cleaned text is stable)

## Known Limitations (v1)

- **VS Code / Cursor excluded** — can't distinguish terminal pane from editor copies
- **Terminal list not user-configurable** — hardcoded set, extensible in future
- **No undo after save** — original text permanently replaced (same as existing edit mode)
- **No content-based fallback** — items without `sourceBundleId` won't show the button
- **CJK/wide characters** — line-width heuristic uses character count, not display width
- **Mode toggle during edit** — must discard, toggle, re-clean (no inline mode switch)

## Future Evolution

- **NL framework:** `NLTokenizer` for sentence boundary detection (smarter reflow)
- **Content analysis fallback:** Detect terminal-like text from any source app
- **Transform pipeline:** "Clean up" as first action; future: summarize, translate, restyle
- **Configurable terminal list** in Settings
- **Before/after diff view** during cleanup preview

## References

- Brainstorm: `docs/brainstorms/2026-02-20-terminal-text-cleanup-brainstorm.md`
- Edit mode pattern: `Sources/Views/ClipboardPanelView.swift:300-371`
- Preview panel: `Sources/Views/PreviewPanel.swift:32-153`
- Source app capture: `Sources/Services/ClipboardMonitor.swift:88-92`
- DB update method: `Sources/Models/ClipboardRecord.swift:97-115`
