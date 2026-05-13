<p align="center">
  <img src="website/public/drobule.png" alt="Drobu mascot" width="120" />
</p>

<h1 align="center">Drobu</h1>

<p align="center">
  <em>Capture, edit, paste. Done.</em><br/>
  A macOS clipboard manager with content actions built in.
</p>

<p align="center">
  <a href="https://danieliusisiunas.github.io/drobu/">Website</a> ·
  <a href="https://github.com/DanieliusIsiunas/drobu/releases/latest/download/Drobu.zip">Download</a> ·
  <a href="LICENSE">License</a>
</p>

---

## What it is

Drobu lives in the menu bar and takes care of everything between "I copied this" and "I pasted this":

Everything stays on your machine. No accounts, no servers, no telemetry. See the [privacy page](https://danieliusisiunas.github.io/drobu/privacy/) for the full statement.

## Architecture

macOS menu bar app, runs as `.accessory` (no dock icon).

| Layer | Tech |
|---|---|
| UI | SwiftUI + AppKit hybrid (`NSPanel` for the floating panel) |
| Persistence | [GRDB](https://github.com/groue/GRDB.swift) over SQLite with FTS5 |
| Hotkeys | [HotKey](https://github.com/soffes/HotKey) |
| Auto-updates | [Sparkle](https://sparkle-project.org/) |

The library target `DrobuCore` contains the app logic; `Drobu` is a thin `@main` entry point. Tests live under `Tests/DrobuTests/` and run on every PR via `.github/workflows/tests.yml`.

The landing page in `website/` is an Astro 6 static site deployed to GitHub Pages via `.github/workflows/deploy-website.yml`.

Database path: `~/Library/Application Support/ClipboardHistory/clipboard.sqlite`

## Build & run

**One-time setup** — create a self-signed code-signing certificate so Accessibility permissions persist across rebuilds (ad-hoc signing rotates the binary hash and revokes TCC grants on every build):

1. Open **Keychain Access**
2. **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name `ClipboardHistoryDev`, identity type **Self-Signed Root**, certificate type **Code Signing**

Then build, install to `/Applications`, and launch:

```bash
pkill -x Drobu 2>/dev/null; ./build.sh --install && open /Applications/Drobu.app
```

Without the cert, the build script falls back to ad-hoc signing — the app still runs, but you'll re-grant Accessibility on every rebuild.

## Tests

```bash
swift test
```

CI enforces this on every PR. Test targets live in `Tests/DrobuTests/` using Swift Testing (`@Test`, `@Suite`).

## Releasing

`release.sh` runs the full Sparkle release flow: build → sign with the Sparkle EdDSA key (read from Keychain) → tag → create a GitHub release → update `website/public/appcast.xml` → push. Bump the version in `Sources/DrobuCore/Info.plist` (both `CFBundleShortVersionString` and `CFBundleVersion`) first, then:

```bash
./release.sh
```

## License

Source is published for transparency and security audit. **All rights reserved** — Drobu is a commercial product; the compiled application is licensed separately. See [LICENSE](LICENSE).
