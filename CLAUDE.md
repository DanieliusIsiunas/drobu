# CLAUDE.md

## Memory Organization

- **This file** (`CLAUDE.md`): Stable project conventions, commands, architecture. Only add things that apply to every session.
- **Auto-memory** (`MEMORY.md`): Session context, preferences, project-specific decisions. Claude manages this.
- **Rules** (`.claude/rules/*.md`): Reusable technical gotchas and workarounds, organized by topic.

When you discover a reusable gotcha or workaround during a session, **proactively append it** to `.claude/rules/<topic>.md` (create the file if needed). Choose a descriptive topic name (e.g., `swiftui-macos-gotchas.md`, `grdb-sqlite.md`). Keep each file focused on one topic.

## Build & Run Commands

```bash
pkill -x Drobu; ./build.sh --install && open /Applications/Drobu.app
```

Always use this combo — kills stale process, rebuilds, installs to `/Applications/`, launches. The `--install` flag copies the bundle to `/Applications/` so SMAppService "Launch at login" points to a stable path.

**Debug helpers:**
- DB inspection: `sqlite3 ~/Library/Application\ Support/ClipboardHistory/clipboard.sqlite`
- App log: `cat ~/Library/Application\ Support/ClipboardHistory/app.log`
- `log show` does NOT work for this app — always use the file-based log above

**Code signing:** `ClipboardHistoryDev` self-signed cert preserves Accessibility permissions across builds. Falls back to ad-hoc without it.

**Tests:** `swift test` — runs 45 tests across 4 suites in ~0.25s. CI runs this on every PR and push to main. Run locally with `swift test` before pushing.

## Testing

**Rule: New logic gets tests.** When adding or modifying code in Models/, Database/, or Services/, write tests alongside the implementation. Tests are not a follow-up task — they ship in the same commit as the feature.

**What to test:**
- Database operations (queries, migrations, CRUD) — use `makeTestDatabase()` for temp-file DatabasePool
- Content extraction logic — use `MockPasteboardItem` with factory methods (`.text()`, `.gif()`, `.image()`)
- Service state machines — test with real dependencies when harmless (e.g., CaffeinateService with real `/usr/bin/caffeinate`)
- Pure functions (text processing, hash computation, type filtering)

**What NOT to test:**
- SwiftUI views, NSPanel lifecycle, AppKit UI wiring
- System singletons (NSPasteboard.general, NSWorkspace.shared) — use protocol abstractions instead
- Apple framework behavior (CryptoKit, ImageIO, SQLite internals)

**Test patterns:**
- Swift Testing framework (`import Testing`, `@Test`, `@Suite`). No XCTest.
- `@MainActor @Suite` for testing `@MainActor`-isolated services
- `makeTestDatabase()` for isolated temp-file databases (cleaned per process)
- `makeRecord(...)` factory for ClipboardRecord with sensible defaults
- `MockPasteboardItem.text/gif/image()` factories for extraction tests
- `defer { service.cleanup() }` for any test that spawns processes

**Run tests:** `swift test` — run locally before pushing. CI enforces this on every PR to main. If a test fails, fix it before proceeding.

## Architecture

macOS menu bar app (SwiftUI + AppKit hybrid, GRDB for SQLite, HotKey for shortcuts). Runs as `.accessory` (no dock icon).

**Core flow:** AppDelegate → ClipboardMonitor (polls pasteboard 0.5s) → AppDatabase (SQLite + FTS5) → FloatingPanel (PanelView)

```
Sources/
├── DrobuCore/     # Library target (all app logic, importable by tests)
│   ├── App/       # AppDelegate, Notification.Name extensions
│   ├── Database/  # AppDatabase (GRDB pool, migrations)
│   ├── Models/    # ClipboardRecord, RetentionDefaults, CaptureHotkeyDefaults
│   ├── Services/  # ClipboardMonitor, SlashCommand, CaffeinateService, ScreenCaptureService, GIFFrameEngine, Log
│   └── Views/     # PanelView (main UI), FloatingPanel, SettingsView, PreviewPanel, GIF views
├── Drobu/         # Executable target (thin @main entry point + SettingsOpenerView)
Tests/
└── DrobuTests/    # Test target (@testable import DrobuCore)
```

DB path: `~/Library/Application Support/ClipboardHistory/clipboard.sqlite`

## Debugging

**First step for any bug:** Read the app log. It captures errors, state transitions, and DB failures.

```bash
cat ~/Library/Application\ Support/ClipboardHistory/app.log
```

The log truncates on every app launch — it only contains the current session. If investigating a crash or past issue, the log may be empty (app restarted). In that case, reproduce the issue first, then read the log.

**`Log` utility** (`Sources/Services/Log.swift`): Async file-based logger using a serial `DispatchQueue`. Three levels: `debug`, `info`, `error`. All messages use `@autoclosure` — safe on hot paths.

**What gets logged automatically:**
- App launch (pid)
- ClipboardMonitor decision breadcrumbs: every change → captured/skipped/rejected with source app, types, sizes, and reason
- Paste flow: what was written to pasteboard, Cmd+V fired or failed
- State transitions: CaffeinateService and ClosedLidService log every `idle ↔ active` change
- DB write failures: ClipboardMonitor upsert, PanelView edit/delete/trim, AppDelegate cleanup/capture
- GRDB ValueObservation errors (PanelView)
- External process failures: ClosedLidService cleanup exit codes + stderr
- Screen capture encoding pipeline (frame counts, GIF sizes, fallback attempts)

**What does NOT get logged** (by design):
- Clipboard content (security: passwords, tokens, private text)
- Successful DB writes (noise: monitor fires every 0.5s)
- Per-frame data in screen capture (hot path: would cause frame drops)

**When adding logging to new code:**
- Use `TypeName: message` format (e.g., `Log.error("MyService: thing failed: \(error)")`)
- Use `do/catch` with `Log.error` instead of `try?` for operations that should produce signal on failure
- Never log clipboard content or user data in the message
- Never add `Log` calls inside `ScreenCaptureService.FrameCaptureOutput.stream()` — it's a hot path at screen refresh rate

## Key Patterns

- **Deduplication:** SHA256 content hash → `upsert()` deletes old + inserts with fresh `createdAt` (moves to top)
- **Suppression:** After paste, `monitor.suppressNextChange()` prevents re-recording the item we just pasted
- **Cleanup:** Runs on launch + hourly. Deletes by age + count. Deferred while panel is visible.
- **Settings persistence:** UserDefaults with immediate save. Hotkey changes post `.hotkeyDidChange` notification.
- **Permissions:** Accessibility (for Cmd+V simulation), Pasteboard (macOS 15.4+ `accessBehavior` check)
- **Panel modes:** `PanelMode.clipboard` (history) and `.commands` (slash commands like `/sleep`)

## Versioning

Semver (`MAJOR.MINOR`). Bump version when merging significant changes to main.

- **Patch (not used):** App is pre-1.0 maturity; small fixes just ship without bumping.
- **Minor (1.0 → 1.1):** New feature that doesn't break existing functionality (e.g., video capture, new slash command).
- **Major (1.x → 2.0):** Breaking changes (schema migration that drops data, removed features, fundamentally different UX).

**Version is hardcoded in 4 places — update all four:**
1. `Sources/Info.plist` — `CFBundleShortVersionString` (display version) and `CFBundleVersion` (build number, incrementing integer for Sparkle)
2. `Sources/Views/SettingsView.swift` — `Text("Drobu v1.1")` in the About section
3. `website/src/components/DownloadCTA.astro` — `Version 1.1` in the download CTA
4. `website/src/components/Footer.astro` — `v1.1` in the footer

`CFBundleVersion` must be strictly increasing for Sparkle update comparison. Bump it as an integer (2, 3, 4...) each release. `CFBundleShortVersionString` is the human-readable semver shown to users.

When a feature is significant enough for a bump (new capability, not just a bug fix), update all 4 files in the same commit.
