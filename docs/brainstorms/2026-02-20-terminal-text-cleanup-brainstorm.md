# Terminal Text Cleanup — Brainstorm

**Date:** 2026-02-20
**Status:** Ready for planning

## What We're Building

A "Clean up" feature in the clipboard history preview panel that reformats terminal-sourced text for clean pasting into apps like Jira and MatterMost.

**The problem:** Text copied from terminal apps (Terminal.app, iTerm2, Cursor, VS Code terminal) contains hard line wraps at terminal width, mixed code/prose without clear boundaries, and raw Markdown artifacts. Pasting this into rich-text-capable apps produces broken formatting.

**The solution:** A "Clean up" button in the preview panel that detects terminal-sourced clips (via `sourceBundleId`) and applies formatting fixes. Two output modes: Clean Markdown and Plain text (reflowed). The user sees the cleaned result in preview before pasting.

## Why This Approach

- **Source app heuristic first** — we already track `sourceBundleId`, so detecting terminal clips is free. Start with known terminal bundle IDs rather than analyzing content structure.
- **Deterministic rules first** — predictable, fast, no dependencies. Evolve to Apple's Natural Language framework (NLTokenizer for sentence boundaries) once the basics prove out.
- **Manual trigger via "Clean up" button** — gives user control, no surprises. The preview panel already supports edit mode, so this fits the existing interaction pattern.
- **Two output modes** — Jira wants Markdown, chat apps sometimes want plain text. A toggle lets the user choose per-clip.

## Key Decisions

1. **Detection:** Source app heuristic via `sourceBundleId` (Terminal.app, iTerm2, Cursor, VS Code, Warp, etc.)
2. **Trigger:** Manual "Clean up" button in preview panel (not auto-applied)
3. **Output formats:** Clean Markdown and Plain text, selectable via toggle
4. **Scope:** Start with deterministic rules, evolve to NL framework for smarter sentence boundary detection
5. **Extension path:** "Clean up" is the first action in what could become a text transformation pipeline (summarize, translate, restyle)

## Formatting Rules (Initial Set)

### Prose Reflow
- Detect hard line wraps: consecutive lines of similar length (within ~5 chars of terminal width) that don't end with punctuation
- Join these into flowing paragraphs
- Preserve intentional paragraph breaks (blank lines between paragraphs)

### Code Block Detection
- Lines with consistent indentation (2+ spaces or tabs)
- Lines containing code syntax markers (braces, semicolons, arrows, pipes)
- Wrap detected code sections in fenced code blocks (```) for Markdown mode

### Markdown Cleanup
- Ensure headings have blank lines before/after
- Normalize bullet list markers (consistent `-` or `*`)
- Properly fence code blocks that were inline in terminal output
- Clean up excessive blank lines (max 2 consecutive)

### Plain Text Mode
- Apply prose reflow only
- Strip Markdown formatting symbols
- Preserve code blocks as-is (indented)

## Open Questions

- Should cleaned text replace the original or create a new clip entry?
- How to handle mixed content (prose paragraph, then code block, then more prose) reliably?
- Should we show a diff/before-after view during cleanup?
- What terminal bundle IDs should we support initially? (Terminal.app, iTerm2, Cursor, VS Code, Warp, Alacritty, kitty)

## Future Evolution (Not for v1)

- **NL framework integration:** Use `NLTokenizer` with `.sentence` unit for smarter reflow decisions
- **Content analysis fallback:** For clips from unknown sources, analyze text structure instead of relying on bundle ID
- **Transform pipeline:** Multiple transforms (clean up, summarize, translate, restyle) in the preview panel
- **Style adjustment:** Tone/formality adjustments using on-device models
