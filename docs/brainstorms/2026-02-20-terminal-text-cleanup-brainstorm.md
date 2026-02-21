# Terminal Text Cleanup — Brainstorm (Refined)

**Date:** 2026-02-20
**Status:** Ready for planning

## What We're Building

A keyboard-triggered text cleanup feature that reformats clipboard text for clean pasting into apps like Jira, MatterMost, and Slack. When in edit mode with the cursor at position 0, pressing arrow up transforms the text into clean Markdown — reflowing hard-wrapped prose, fencing code blocks, and normalizing structure.

**The problem:** Text copied from terminals and other sources often contains hard line wraps at terminal width, mixed code/prose without clear boundaries, ANSI escape sequences, and raw formatting artifacts. Pasting into rich-text-capable apps produces broken formatting.

**The solution:** A keyboard-driven cleanup action accessible from edit mode. No button, no mode picker — just arrow up at the top of the text field. The transformation produces clean Markdown output and enters edit mode so the user can review before saving.

## Why This Approach

- **Keyboard-first UX** — no buttons or pickers. Right arrow enters edit mode, arrow up at position 0 triggers cleanup. Feels natural for power users and matches the app's keyboard-driven design.
- **Available for all text clips** — not gated on source app. Users decide when cleanup is useful, regardless of whether the text came from a terminal, editor, or browser.
- **Markdown only** — most target apps (Jira, Slack, MatterMost, GitHub) render Markdown. A single output format keeps the feature simple. Plain text mode can be added later if needed.
- **Deterministic rules** — predictable, fast, no dependencies. Pure function with no side effects.
- **Reuses edit mode** — cleanup populates the existing edit field. All save/discard behavior works as-is. No new UI patterns needed.
- **ANSI stripping at capture** — never store escape sequences in the database. This is a baseline quality improvement for all clips, not just cleaned ones.

## Key Decisions

1. **Scope:** Available for ALL text clips — no source app gating or bundle ID matching
2. **Output format:** Markdown only — no mode picker, no plain text option
3. **Trigger:** Keyboard-only — arrow up when cursor is at position 0 in edit mode
4. **No UI elements:** No "Clean up" button, no segmented picker, no toolbar
5. **Save behavior:** Replace original text (matches existing edit-mode behavior)
6. **ANSI stripping:** Done at capture time in ClipboardMonitor, not during cleanup
7. **Pure function:** `TerminalTextCleaner.clean(_:) -> String` — stateless, testable

## User Flow

1. Select a text clip in the panel
2. Press right arrow to enter edit mode (cursor starts at position 0)
3. Press arrow up — cleanup runs, text is replaced with cleaned Markdown
4. Review the result, optionally make manual tweaks
5. Cmd+Return to save (replaces original), or Escape to discard

## Formatting Rules

### Prose Reflow
- Detect hard line wraps: consecutive lines of similar length (within ~5 chars of terminal width) that don't end with sentence-ending punctuation
- Join into flowing paragraphs
- Preserve intentional paragraph breaks (blank lines)

### Code Block Detection
- Lines with consistent indentation (4+ spaces or tabs)
- Lines containing code syntax markers (braces, semicolons, arrows, pipes, etc.)
- Wrap in fenced code blocks (```)

### Structure Normalization
- Ensure headings have blank lines before/after
- Normalize bullet list markers (consistent `-`)
- Collapse excessive blank lines (max 1 between blocks)

### ANSI Stripping (at capture time)
- Strip all ANSI escape sequences (`\x1B[...m`, etc.) when ClipboardMonitor captures text
- Applies to all text clips, not just cleanup targets

## Open Questions (Resolved)

- ~~Should cleaned text replace the original or create a new clip?~~ **Replace original.**
- ~~VS Code/Cursor exclusion?~~ **Not applicable — available for all text clips.**
- ~~Before/after diff view?~~ **No — edit mode with Escape-to-discard is sufficient.**
- ~~Two output modes?~~ **Markdown only.**
- ~~Button placement?~~ **No button — keyboard trigger only.**

## Known Limitations (v1)

- **No undo after save** — original text permanently replaced (same as existing edit mode)
- **CJK/wide characters** — line-width heuristic uses character count, not display width
- **No plain text mode** — Markdown only for now
- **Not discoverable** — keyboard gesture must be learned (could document in onboarding/help later)

## Future Evolution (Not for v1)

- **Plain text output mode** — add toggle if users need it
- **NL framework integration** — `NLTokenizer` for smarter sentence boundary detection
- **Content analysis** — detect code language for fenced block annotations
- **Transform pipeline** — cleanup as first action; future: summarize, translate, restyle
- **Discoverability** — tooltip or hint when entering edit mode on long text
