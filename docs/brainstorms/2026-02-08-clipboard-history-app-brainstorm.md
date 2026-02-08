# Clipboard History — Standalone macOS App

**Date:** 2026-02-08
**Status:** Brainstorm complete, ready for planning

## What We're Building

A standalone, single-purpose macOS app that replicates Alfred's clipboard history feature. A "nano app" laser-focused on making copy-paste a superpower — nothing more, nothing less.

The app monitors the system clipboard, stores history in SQLite, and presents a searchable floating panel on a global hotkey. Selecting an item auto-pastes it into the frontmost application.

## Why This Approach

**SwiftUI + NSWindow backing (Approach 3):**
- SwiftUI for all UI (search field, history list, image previews, timestamps) — fast to build, native look & feel, automatic light/dark mode
- AppKit (`NSPanel`/`NSWindow`) only for the floating panel window behavior and global hotkey registration — these are the two things SwiftUI can't do alone
- Keeps the codebase modern and minimal while getting precise control where it matters

**Why not the alternatives:**
- Pure menu bar popover (Approach 1): Too constrained for search UX and panel positioning
- AppKit-first (Approach 2): Unnecessary boilerplate for a focused app like this

## Key Decisions

1. **Platform:** macOS native, Swift/SwiftUI
2. **UI framework:** SwiftUI for views, NSPanel for window management
3. **Storage:** SQLite (via GRDB.swift or raw SQLite3) — proven at scale for clipboard data, fast full-text search
4. **Clipboard types:** Text, images, and file lists — all three from day one
5. **Core interaction:** Global hotkey opens floating panel → type to search → select to auto-paste → panel dismisses
6. **Distribution:** Personal use, unsigned — full accessibility API access, no sandbox restrictions
7. **App style:** Native macOS appearance, follows system light/dark mode, uses standard vibrancy/materials

## v1 Scope

### Must Have
- Global hotkey to toggle the clipboard viewer panel
- Clipboard monitoring (poll `NSPasteboard` for changes)
- Store text, images, and file lists in SQLite
- Searchable list with fuzzy matching
- Image thumbnails in the list
- Auto-paste selected item into frontmost app (via accessibility/CGEvent)
- Configurable retention (e.g., 7 days text, 24h images)
- App source type indicators (terminal icon, browser icon, etc.)
- Keyboard navigation (arrow keys, return to select, escape to dismiss)

### Not in v1 (future)
- App ignore list (skip 1Password, Keychain, etc.)
- Concealed/auto-generated clipboard data filtering
- Snippets / pinned items
- Merging / appending clipboard items
- Universal clipboard filtering
- iCloud sync
- Mac App Store distribution

## Technical Notes

- **Clipboard monitoring:** `NSPasteboard.general.changeCount` polling on a timer (every 0.5s). No notification API exists for clipboard changes on macOS.
- **Auto-paste:** Use `CGEvent` to simulate Cmd+V in the frontmost app after placing the selected item on the clipboard. May need Accessibility permission.
- **Global hotkey:** Use `Carbon` hotkey API (`RegisterEventHotKey`) or a Swift wrapper library. SwiftUI doesn't support global hotkeys natively.
- **Window behavior:** `NSPanel` with `.nonactivatingPanel` style mask, floating window level. This is how Alfred's panel works — it appears without stealing focus from the frontmost app until interaction.
- **Image storage:** Store image data as blobs in SQLite, generate thumbnails on insert for fast list rendering.

## Open Questions

- What global hotkey to use? (Alfred uses Ctrl+Opt+Shift+Cmd+C — quite a chord)
- Maximum history size / auto-cleanup strategy?
- Should the search be substring, fuzzy, or both?
