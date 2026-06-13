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

**Code signing:** `build.sh` signs with the **Developer ID Application** cert (`Developer ID Application: DANIELIUS ISIŪNAS (TGL69S88MD)`), hardened runtime + `--timestamp`, so the same bundle can be notarized for release and dev builds keep a stable signature (Accessibility persists). The cert name is resolved dynamically from Keychain. If it's missing, the build **fails loudly** — it does NOT fall back to ad-hoc signing (which would reset TCC and break Sparkle updates for installed users). The legacy self-signed `ClipboardHistoryDev` cert is no longer used. Details in `.claude/rules/sparkle-macos-gotchas.md`.

**Release pipeline:** `./release.sh` builds + Developer-ID-signs the app, **notarizes and staples** both the `.app` and the `Drobu.dmg` (drag-to-Applications layout via `create-dmg` — `brew install create-dmg` once per dev machine), then Sparkle-EdDSA-signs the *stapled* DMG (stapling rewrites the bytes, so the EdDSA signature/length must be computed last), **runs the pre-publish verification gate**, tags + pushes, creates the GitHub Release, updates `website/public/appcast.xml`, and **runs the post-publish synthetic-update-client check**. Bump version in `Sources/DrobuCore/Info.plist` first.

**Release verification gate:** `tools/verify-release.sh` (`--pre` blocks publishing on any artifact/contract defect; `--post` verifies the live appcast + downloaded enclosure exactly as a Sparkle client would, and runs standalone any time as a health check). After ANY edit to the verifier, run `tools/e2e/verify-release-selftest.sh` — it proves every check still fires, live against the latest published release. **Never add `spctl --assess` to release checks for the DMG** — the container is deliberately not codesigned and spctl false-rejects it (this aborted the v1.4.1 release); `stapler validate` is the authoritative ticket check. The gate's network checks deliberately block during a GitHub/Pages outage: if the appcast host is down, shipped clients can't update either. Recovery procedures: `docs/private/support-runbook.md`.

Notarization needs a one-time keychain profile (the script preflights for it and prints the command if missing):
```bash
xcrun notarytool store-credentials "notary-profile" \
    --apple-id <apple-id> --team-id TGL69S88MD --password <app-specific-password>
```
The app-specific password comes from appleid.apple.com → Sign-In and Security → App-Specific Passwords (NOT your Apple ID password). The first notarized release migrates installed self-signed clients over Sparkle's EdDSA path — safe **only** because `SUPublicEDKey` stays unchanged; never rotate the EdDSA key and the signing cert in the same release.

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

**Customer state:** stored in the user's Keychain (service `com.danielius.ClipboardHistory.license`; accounts `trial-start`, `active-license`, and `last-seen` — the clock-rollback anchor). Survives `defaults delete`. Reset and diagnostic procedures live in the private support runbook (`docs/private/support-runbook.md` — local only, gitignored).

**Issuing keys:** fulfillment is **automated** — a Stripe payment hits `supabase/functions/stripe-webhook`, which vends a pre-signed key from a Postgres pool (minted offline via `./tools/mint-license-pool.sh`; the Ed25519 private key never leaves the dev Keychain) and emails it within ~1 minute. Manual fallback for outages/support:
```bash
./tools/issue-license-key.sh customer@example.com --session cs_XXXX
```
`--session` keeps one-payment-one-key idempotency intact (checks for an existing vend first, records the claim upstream). Both paths append to `tools/license-log.csv` (gitignored) for the audit trail.

**Operational runbook:** `docs/licensing.md` covers the public model, key rotation, the payment-link contract, and the automated-fulfillment architecture. Support diagnostics, reset procedures, fulfillment failure playbooks, and the detailed threat model live in `docs/private/support-runbook.md` (gitignored). **Plans and audits touching licensing internals go to `docs/private/`, not `docs/plans/`** — this repo is public.

**Price is set in many places — change all of them in the same pass (mirror the version checklist):**
1. The Stripe Payment Link — edit the price on the **existing** link in the dashboard; never create a new link and deactivate the old one (shipped binaries point at the old URL forever)
2. `Sources/DrobuCore/Views/ActivationView.swift` — 3 strings (subtitle, Buy button, accessibility label)
3. `Sources/DrobuCore/Views/SettingsView.swift` — 2 strings (Buy row + accessibility label)
4. `website/src/components/Hero.astro`
5. `website/src/components/DownloadCTA.astro`
6. `website/src/layouts/Landing.astro` — meta description **and** JSON-LD `"price"`
7. `website/src/pages/terms.astro`
8. This file (the Pricing line above)
9. The fulfillment webhook's `AMOUNT_FLOOR` Supabase secret (`supabase secrets set AMOUNT_FLOOR=<minor units>`) — a log-only sanity signal that never blocks fulfillment; set it below the lowest legitimate localized price so below-floor transactions leave a visible breadcrumb

## Debugging

**First step for any bug:** Read the app log. It captures errors, state transitions, and DB failures.

```bash
cat ~/Library/Application\ Support/ClipboardHistory/app.log
```

Each launch starts a fresh log — `app.log` only contains the current session; the **previous** session is rotated to `app.log.1`. If investigating a crash or past issue, the current log may be empty (app restarted) — check `app.log.1` for the prior session, or reproduce the issue first, then read `app.log`.

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

Semver (`MAJOR.MINOR.PATCH`). Bump version when merging changes worth shipping to main.

- **Patch (1.3 → 1.3.1):** Small enhancements, refinements to an existing feature, or bug fixes worth a release (e.g., Esc-to-stop recording, panel behavior tweaks). The patch tier is first-class — prefer it over a minor bump when the change extends or polishes something users already have rather than giving them a distinctly new capability.
- **Minor (1.3 → 1.4):** A distinctly new user-facing capability (e.g., video capture, a new slash command, file-copy support).
- **Major (1.x → 2.0):** Breaking changes (schema migration that drops data, removed features, fundamentally different UX).

Truly trivial changes (docs, internal refactors, CI) don't need a bump — they just ride the next release.

`CFBundleShortVersionString` is the human-readable `MAJOR.MINOR.PATCH` string shown to users. `CFBundleVersion` is a **separate, strictly-increasing integer** build number for Sparkle's update comparison — increment it by one every release (2, 3, 4, 5...) regardless of which semver component changed.

**Version is set in 3 places — update all of them in the same commit as the change:**
1. `Sources/DrobuCore/Info.plist` — `CFBundleShortVersionString` (display version) and `CFBundleVersion` (build number)
2. `website/src/components/DownloadCTA.astro` — `Version X.Y.Z` in the download CTA
3. `website/src/components/Footer.astro` — `vX.Y.Z` in the footer

The Settings "About" text reads `CFBundleShortVersionString` at runtime (`SettingsView.swift`), so it updates automatically — no edit needed there.
