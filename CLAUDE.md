# CLAUDE.md

## Memory Organization

- **This file** (`CLAUDE.md`): Stable project conventions, commands, architecture. Only add things that apply to every session.
- **Auto-memory** (`MEMORY.md`): Session context, preferences, project-specific decisions. Claude manages this.
- **Rules** (`.claude/rules/*.md`): Reusable technical gotchas and workarounds, organized by topic.

When you discover a reusable gotcha or workaround during a session, **proactively append it** to `.claude/rules/<topic>.md` (create the file if needed). Choose a descriptive topic name (e.g., `swiftui-macos-gotchas.md`, `grdb-sqlite.md`). Keep each file focused on one topic.

## Build & Run Commands

```bash
pkill -x ClipboardHistory && ./build.sh && open .build/ClipboardHistory.app
```

Always use this combo — kills stale process, rebuilds, launches.

**Debug helpers:**
- DB inspection: `sqlite3 ~/Library/Application\ Support/ClipboardHistory/clipboard.sqlite`
- Logs don't show in `log show` — use file-based logging to `~/Desktop/` when debugging

**Code signing:** `ClipboardHistoryDev` self-signed cert preserves Accessibility permissions across builds. Falls back to ad-hoc without it.

## Architecture

macOS menu bar app (SwiftUI + AppKit hybrid, GRDB for SQLite, HotKey for shortcuts). Runs as `.accessory` (no dock icon).

**Core flow:** AppDelegate → ClipboardMonitor (polls pasteboard 0.5s) → AppDatabase (SQLite + FTS5) → FloatingPanel (PanelView)

```
Sources/
├── App/           # AppDelegate, ClipboardHistoryApp (entry point)
├── Database/      # AppDatabase (GRDB pool, migrations)
├── Models/        # ClipboardRecord, RetentionDefaults, CaptureHotkeyDefaults
├── Services/      # ClipboardMonitor, SlashCommand, CaffeinateService, ScreenCaptureService, GIFFrameEngine
└── Views/         # PanelView (main UI), FloatingPanel, SettingsView, PreviewPanel, GIF views
```

DB path: `~/Library/Application Support/ClipboardHistory/clipboard.sqlite`

## Key Patterns

- **Deduplication:** SHA256 content hash → `upsert()` deletes old + inserts with fresh `createdAt` (moves to top)
- **Suppression:** After paste, `monitor.suppressNextChange()` prevents re-recording the item we just pasted
- **Cleanup:** Runs on launch + hourly. Deletes by age + count. Deferred while panel is visible.
- **Settings persistence:** UserDefaults with immediate save. Hotkey changes post `.hotkeyDidChange` notification.
- **Permissions:** Accessibility (for Cmd+V simulation), Pasteboard (macOS 15.4+ `accessBehavior` check)
- **Panel modes:** `PanelMode.clipboard` (history) and `.commands` (slash commands like `/sleep`)
