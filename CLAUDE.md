# CLAUDE.md

## Build & Run Commands

```bash
pkill -x ClipboardHistory && ./build.sh && open .build/ClipboardHistory.app
```

Kill → build → launch. Always use this combo (stale binaries persist otherwise).

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

## Settings Scene Gotchas

The `Settings` scene switches activation policy: `.accessory` → `.regular` (open) → `.accessory` (close).

- **Buttons don't receive clicks** inside grouped `Form`. Use `Text` + `.onTapGesture` instead of `Button`.
- **`NSApp.delegate as? AppDelegate` returns nil**. Access shared resources directly (e.g. `AppDatabase()`).
- **`.alert` / `.confirmationDialog` actions silently never fire**. Use `NSAlert.beginSheetModal(for: NSApp.keyWindow!)`.
