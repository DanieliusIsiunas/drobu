# Slash Commands System — Brainstorm

**Date:** 2026-02-26
**Status:** Ready for planning

## What We're Building

A slash command system for ClipboardHistory that transforms the search bar into a command palette. When the user types `/` in the search bar, the panel switches from clipboard mode to command mode, showing available commands. The first command is `/sleep` — macOS sleep prevention via `caffeinate`.

This turns ClipboardHistory from a clipboard manager into a lightweight keyboard-driven utility launcher.

## Core UX Flow

1. User opens panel (global hotkey)
2. Types `/` — panel switches to **command mode**, showing all registered commands
3. Continues typing (e.g., `/sleep`) — list filters to matching commands
4. Selects a command with arrow keys + Return — command options replace the list
5. Selects an option (e.g., "1 hour") — action executes, panel closes
6. Escape at any point returns to clipboard mode or closes panel

## Key Decisions

### Panel Mode System
- **Rename** `ClipboardPanelView` → `PanelView`
- Add `panelMode` state enum: `.clipboard`, `.command` (extensible to others later)
- Typing `/` as first character triggers mode switch to `.command`
- Deleting the `/` returns to `.clipboard` mode
- Same keyboard navigation (arrow keys, Return, Escape) works in both modes

### Command Mode Behavior
- Typing just `/` shows **all available commands** as a browsable list
- Each command row: icon + name + short description
- Arrow key navigation and Return to select, same as clipboard items
- Selecting a command shows its **options** (e.g., duration choices for `/sleep`)

### `/sleep` Command (Caffeinate)
- **Duration options:** 15 min, 30 min, 1 hour, 2 hours, 4 hours (no indefinite — always auto-stops)
- **Activation:** Selecting a duration runs `caffeinate -dims -t <seconds>` as a background process
- **Menu bar indicator:** Small green dot badge on the existing clipboard icon when active
- **Re-entry:** Opening `/sleep` while active shows status ("Sleep prevention active — 42 min remaining") with cancel option alongside duration options
- **Cancellation:** Selecting cancel kills the caffeinate process, removes the dot badge

### Architecture
- **Lightweight protocol** for commands — build what `/sleep` needs, extract patterns when a second command arrives
- `SlashCommand` protocol: `name`, `icon`, `description`, `options` (dynamic), `execute(option:)`
- Each command is a conforming type (e.g., `SleepCommand`)
- Command registry: simple array of `SlashCommand` instances for now

### Panel View Reuse
- Command options rendered in the **same ScrollView + LazyVStack** as clipboard items
- Reuses existing arrow key navigation, selection highlighting, Return-to-act pattern
- Preview panel (right side): **minimal status only** — shows live countdown when caffeinate is active, otherwise empty/hidden

### Search Bar in Command Mode
- **Placeholder text changes** from "Search..." to "Type a command..." when `/` is typed
- No other visual changes to the search bar — the list content switching is the primary mode indicator

### Menu Bar Indicator
- **Small dot badge** (green) overlaid on the existing clipboard menu bar icon
- Subtle but visible — doesn't replace or recolor the icon itself
- Removed when caffeinate stops (timer expires or manually cancelled)

## Why This Approach

**Mode switch inside PanelView** was chosen over separate views or overlays because:
- Reuses all existing keyboard navigation and selection logic
- Minimal new views — command options are just rows in the same list
- Matches the "full replacement" UX — typing `/` seamlessly transforms the panel
- Single view responsibility stays manageable with enum-based mode switching

## Resolved Questions

1. **Menu bar icon:** Small green dot badge on existing icon
2. **Caffeinate flags:** `-dims` (all sleep types) — no user choice, keep it simple
3. **Preview panel:** Minimal status only — live countdown when active, empty otherwise
4. **Search bar visual:** Placeholder text change only ("Type a command...")
5. **Architecture:** Lightweight protocol — build for `/sleep`, refactor when second command arrives

## Open Questions

1. **Future commands:** What other slash commands are envisioned? (Validates protocol design without over-building)

## Technical Notes

- `caffeinate` is a native macOS binary at `/usr/bin/caffeinate` — no dependencies
- `caffeinate -dims -t 3600` prevents all sleep types for 1 hour, then exits
- Process management: store the `Process` reference to allow cancellation via `terminate()`
- Timer for remaining-time display: compute from start time + duration, update every second
- Menu bar badge: draw a small filled circle on the NSImage via Core Graphics overlay
