# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

**CRITICAL: Always use the combo command to rebuild and run the app:**

```bash
pkill -x ClipboardHistory && ./build.sh && open .build/ClipboardHistory.app
```

This pattern is essential because:
- Kills the running app to prevent stale binaries
- Builds in release mode with proper code signing
- Creates the app bundle correctly at `.build/ClipboardHistory.app`

**Individual commands:**
- `./build.sh` - Build release version with code signing (creates `.build/ClipboardHistory.app`)
- `swift build` - Debug build (but won't create proper app bundle)
- `pkill -x ClipboardHistory` - Kill running app

**Code signing:** The build script uses a self-signed certificate (`ClipboardHistoryDev`) to maintain stable code signatures across builds, preserving Accessibility permissions. Without this certificate, it falls back to ad-hoc signing (which resets permissions each build).

## Architecture Overview

**Type:** macOS menu bar app (accessory) with global hotkey activation

**Tech Stack:**
- SwiftUI + AppKit hybrid
- GRDB for SQLite database
- HotKey library for global shortcuts

**Core Pattern:** The app runs as an "accessory" (no dock icon) with:
1. **AppDelegate** - Central coordinator, manages lifecycle
2. **ClipboardMonitor** - Polls pasteboard every 0.5s, saves changes to DB
3. **FloatingPanel** - On-demand popup window triggered by global hotkey
4. **AppDatabase** - GRDB database pool, migrations, schema

## Key Components

### Database Layer (`Sources/Database/`, `Sources/Models/`)

**AppDatabase.swift:**
- SQLite database at `~/Library/Application Support/ClipboardHistory/clipboard.sqlite`
- Uses GRDB's DatabasePool for concurrent access
- Migrations registered in `migrator` property
- FTS5 virtual table for full-text search on `plainText`

**ClipboardRecord.swift:**
- Primary model: `id`, `kind`, `plainText`, `imageData`, `contentHash`, `createdAt`, `sourceApp`, `sourceBundleId`
- Deduplication via unique `contentHash` index (SHA256 of content)
- `upsert()` deletes old duplicate by hash, then inserts with fresh `createdAt` (moves to top)
- `cleanup()` enforces retention policy: deletes by age AND count limit
- `search()` uses FTS5 with prefix matching on last token

**RetentionDefaults.swift:**
- UserDefaults wrapper for retention settings (days, max items)

### Monitoring (`Sources/Services/`)

**ClipboardMonitor:**
- Polls `NSPasteboard.general` every 0.5s
- Ignores transient/concealed types (password managers: `org.nspasteboard.TransientType`, etc.)
- Extracts text (1MB cap) or image (10MB cap), deduplicates by hash
- **Suppression:** `suppressNextChange()` / `suppressChanges(count:)` prevent recording programmatic pastes
- Writes to DB on background task (`Task.detached`)
- **macOS 15.4+ pasteboard privacy:** Checks `accessBehavior` on poll failure, calls `onAccessDenied` callback

### UI Layer (`Sources/Views/`)

**FloatingPanel.swift:**
- Borderless, non-activating window centered on screen
- Level: `.floating` (above most windows)
- Auto-closes on focus loss (via delegate)

**ClipboardPanelView.swift:**
- Main panel UI: search bar + scrollable list
- Fetches items from DB (via GRDB observation)
- Handles paste action: writes to pasteboard, simulates Cmd+V (if Accessibility granted)
- Suppresses monitor after paste to prevent re-recording

**SettingsView.swift:**
- SwiftUI form with sections: General, Storage & Retention, About
- Global hotkey recorder (custom NSView wrapper)
- Launch at login toggle (`SMAppService`)
- Retention settings: days (1-365), max items (100-50,000)

**HotkeyRecorderView.swift:**
- Custom NSView wrapped in `NSViewRepresentable`
- Click-to-record pattern: captures key combo via `keyDown(with:)`
- Saves to UserDefaults as `KeyCombo.dictionary`
- Posts `.hotkeyDidChange` notification

### App Lifecycle (`Sources/App/`)

**AppDelegate:**
- Initializes database, starts clipboard monitor
- Registers global hotkey (default: Cmd+Shift+V)
- Runs cleanup on launch + hourly (Timer)
- Cleanup deferred if panel is visible
- Loads retention settings from UserDefaults before each cleanup
- Shows onboarding alerts for Accessibility and Pasteboard permissions

**ClipboardHistoryApp:**
- Menu bar extra (no dock icon)
- Settings window via `Settings` scene
- `SettingsOpenerView`: Opens settings via menu, switches activation policy to `.regular` (temporarily), then back to `.accessory` on close

## Important Patterns

### Deduplication
- Content is hashed (SHA256) before insertion
- `upsert()` deletes old record with same hash, then inserts new with fresh timestamp
- This moves duplicates to top instead of ignoring them

### Suppression
After pasting from the app, the monitor suppresses the next clipboard change to avoid re-recording:
```swift
monitor.suppressNextChange()
pasteboard.setString(text, forType: .string)
// Simulate paste...
```

### Cleanup
Runs on launch + hourly:
1. Delete items older than retention days
2. Delete overflow beyond max item count (keeps most recent)
3. Deferred if panel is visible (no interruptions)

### Settings Persistence
Uses UserDefaults with immediate save:
- `HotkeyDefaults.save()` → posts `.hotkeyDidChange`

AppDelegate observes hotkey notification and re-applies settings.

### Permissions
- **Accessibility:** Required for simulating Cmd+V. Checked on first paste. Without it, items are only copied (manual paste required).
- **Pasteboard (macOS 15.4+):** Runtime check via `accessBehavior` key-value coding. Alert shown if denied.

## Database Schema

**clipboardItem table:**
- `id` INTEGER PRIMARY KEY AUTOINCREMENT
- `kind` TEXT NOT NULL ('text' | 'image')
- `plainText` TEXT (nullable)
- `imageData` BLOB (nullable)
- `contentHash` TEXT NOT NULL (unique index)
- `createdAt` DATETIME NOT NULL (indexed)
- `sourceApp` TEXT
- `sourceBundleId` TEXT

**clipboardItemFts virtual table:**
- FTS5 on `plainText`
- Synchronized with `clipboardItem` table
- Uses unicode61 tokenizer

## Code Organization

```
Sources/
├── App/           # Entry point, AppDelegate, lifecycle
├── Database/      # AppDatabase, GRDB setup
├── Models/        # ClipboardRecord, RetentionDefaults, HotkeyDefaults
├── Services/      # ClipboardMonitor
├── Views/         # SwiftUI + AppKit UI components
└── Info.plist     # Bundle metadata, permissions (NSPrincipalClass)
```

## Settings Windows

The app switches activation policy when opening settings:
- Normal state: `.accessory` (no dock icon, menu bar only)
- Settings open: `.regular` (dock icon, can be focused)
- Settings close: back to `.accessory`

This is handled by `SettingsOpenerView` observing `NSWindow.willCloseNotification`.

## Known macOS SwiftUI Settings Scene Gotchas

- **Buttons don't receive clicks** inside grouped `Form` in `Settings` scene. Use `Text` + `.onTapGesture` instead of `Button`.
- **`NSApp.delegate as? AppDelegate` returns nil** in Settings scene context. Access shared resources directly (e.g. `AppDatabase()`) instead of going through the delegate.
- **`.alert` / `.confirmationDialog` actions silently never fire** in Settings scenes at any attachment level (HStack, Section, Form). Use `NSAlert.beginSheetModal(for: NSApp.keyWindow!)` for confirmation dialogs.
- **`NSLog` may not appear in `log show`** for this app. Use file-based logging to `~/Desktop/` when debugging.
