# CLAUDE.md

## Memory Organization

- **This file** (`CLAUDE.md`): Stable project conventions, commands, architecture. Only add things that apply to every session.
- **Auto-memory** (`MEMORY.md`): Session context, preferences, project-specific decisions. Claude manages this.
- **Rules** (`.claude/rules/*.md`): Reusable technical gotchas and workarounds, organized by topic.

When you discover a reusable gotcha or workaround during a session, **proactively append it** to `.claude/rules/<topic>.md` (create the file if needed). Choose a descriptive topic name (e.g., `swiftui-macos-gotchas.md`, `grdb-sqlite.md`). Keep each file focused on one topic.

### When to capture a learning (concrete triggers)

The proactive-append discipline only works if it fires on specific moments. Capture a rules entry **as soon as any of these fire** — not at end of session:

- You just fixed a CI/build failure that wasn't a typo (cache invalidation, signing drift, missing toolchain, path issue)
- A tool silently fell back to a degraded mode (build script ad-hoc signing, openssl wrong algorithm, hdiutil flat DMG, swift test cache miss)
- You hit a macOS / Keychain / framework quirk that took more than ~10 minutes to diagnose
- You catch yourself thinking *"I keep forgetting this"* or *"that's surprising"* or *"why is this even like this"*
- A multi-round thread (5+ iterations of a single problem) yielded a meta-lesson worth a future-self note

Cost of capture: ~5 minutes. Cost of skipping: re-discovery on the next iteration, every future similar event.

## Build & Run Commands

```bash
pkill -x Drobu; ./build.sh --install && open /Applications/Drobu.app
```

Always use this combo — kills stale process, rebuilds, installs to `/Applications/`, launches. The `--install` flag copies the bundle to `/Applications/` so SMAppService "Launch at login" points to a stable path.

**Debug helpers:**
- DB inspection: `sqlite3 ~/Library/Application\ Support/ClipboardHistory/clipboard.sqlite`
- App log: `cat ~/Library/Application\ Support/ClipboardHistory/app.log`
- `log show` does NOT work for this app — always use the file-based log above

**Code signing:** `ClipboardHistoryDev` self-signed cert preserves Accessibility permissions across builds. Falls back to ad-hoc without it. **Watch for trust drift** — the cert can be present in Keychain but lose `Always Trust` status (`security find-identity -v -p codesigning` returns 0 valid identities even though the cert exists). Details in `.claude/rules/sparkle-macos-gotchas.md`.

**Release pipeline:** `./release.sh` produces a signed `Drobu.dmg` with the drag-to-Applications window layout (via `create-dmg` Homebrew package — `brew install create-dmg` once per dev machine), signs it with the Sparkle EdDSA key from Keychain, tags + pushes, creates the GitHub Release, and updates `website/public/appcast.xml`. Bump version in `Sources/DrobuCore/Info.plist` first.

**Tests:** `swift test` — runs ~73 tests across 5 suites in ~0.2s. CI runs this on every PR and push to main. Run locally with `swift test` before pushing.

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

**License gate:** AppDelegate also instantiates `LicenseManager.shared` on launch. When the user invokes the hotkey, `showPanel()` checks the manager's status — if `.trialExpired` (and no valid license key), `ActivationPanel` opens instead of `FloatingPanel`. ClipboardMonitor keeps running regardless, so the user's history is preserved across the gate.

```
Sources/
├── DrobuCore/     # Library target (all app logic, importable by tests)
│   ├── App/       # AppDelegate, Notification.Name extensions
│   ├── Database/  # AppDatabase (GRDB pool, migrations)
│   ├── Models/    # ClipboardRecord, RetentionDefaults, CaptureHotkeyDefaults
│   ├── Services/  # ClipboardMonitor, LicenseManager (+ LicenseError), SlashCommand, CaffeinateService, ScreenCaptureService, GIFFrameEngine, Log
│   └── Views/     # PanelView (main UI), FloatingPanel, ActivationPanel, ActivationView, SettingsView, PreviewPanel, GIF views
├── Drobu/         # Executable target (thin @main entry point + SettingsOpenerView)
Tests/
└── DrobuTests/    # Test target (@testable import DrobuCore)
```

DB path: `~/Library/Application Support/ClipboardHistory/clipboard.sqlite`

## Commercial model & Licensing

**Pricing:** $14.99 one-time purchase, **14-day in-app free trial** (no payment method required upfront). After day 14 without a license key, the floating clipboard panel is hard-gated by `ActivationPanel`; clipboard monitoring continues so user data is preserved.

**Funnel (trial-first):** website CTAs link directly to the latest signed DMG download — no Stripe in the pre-trial path. Stripe is only reached from inside Drobu (ActivationPanel Buy button or Settings → License) and on the post-payment `/thank-you/` page.

**License keys:** Ed25519 cryptographic signatures, verified offline via `CryptoKit.Curve25519.Signing`. Format: `DROBU-<base64url(32-byte payload)>.<base64url(64-byte signature)>`.

**Public key:** baked into `Sources/DrobuCore/Info.plist` as `DrobuLicensePublicKey` (base64-encoded 32 bytes). Re-generate via `./tools/generate-license-keypair.sh` (destructive — invalidates every previously-issued key).

**Private key:** developer's login Keychain (account `drobu-license-ed25519`, service `com.danielius.ClipboardHistory.license-signing`). Never enters the repo, never enters CI. Back up via Keychain Access → File → Export.

**Customer state:** stored in user's Keychain (service `com.danielius.ClipboardHistory.license`, accounts `trial-start` and `active-license`). Survives `defaults delete`. Wipe with `security delete-generic-password -s "com.danielius.ClipboardHistory.license" -a <account>`.

**Issuing keys (manual workflow for early customers):**
```bash
./tools/issue-license-key.sh customer@example.com
```
Prints the key. Email it. The script appends to `tools/license-log.csv` (gitignored) for audit trail. The Stripe webhook automation that replaces this manual step is out of scope until traffic justifies it.

**Operational runbook:** `docs/licensing.md` covers threat model, refund/revocation, key rotation, and the future webhook plan.

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
