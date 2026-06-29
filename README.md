<p align="center">
  <img src="website/public/drobule.png" alt="Drobu mascot" width="120" />
</p>

<h1 align="center">Drobu</h1>

<p align="center">
  <em>The clipboard you can edit.</em><br/>
  A macOS clipboard manager you can edit: capture, crop, trim, search, and paste it all back from one panel.
</p>

<p align="center">
  <a href="https://drobu.app">Website</a> ·
  <a href="https://github.com/DanieliusIsiunas/drobu/releases/latest/download/Drobu.dmg">Download</a> ·
  <a href="LICENSE">License</a>
</p>

---

## What it is

**Drobu is a macOS clipboard manager you can edit.** It lives in the menu bar and takes care of everything between "I copied this" and "I pasted this":

- **Capture anything** — text, links, images, GIFs, files, and screen recordings all land in one searchable history.
- **Edit in place** — crop a screenshot, trim a GIF or recording, or clean up copied text without a detour through Preview or QuickTime.
- **Search and paste fast** — full-text search across everything you copied; paste one item or a whole stack with a single keystroke.

Your clipboard stays on your machine. No account, no tracking, no ads, and password-manager items are ignored automatically. It is a one-time **$14.99** purchase (not a subscription) with a 14-day free trial, and it runs on macOS 14 and later. (A paid license activates online to enforce a 3-device limit; see the [privacy page](https://drobu.app/privacy/) — including [how to verify it sends nothing](https://drobu.app/privacy/#verify) — for the full statement.)

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

**One-time setup** — `build.sh` signs with the **Apple Developer ID Application** certificate (Apple Developer Program), which gives builds a stable signature so Accessibility permissions persist across rebuilds and lets releases be notarized. Install the cert into your login Keychain via **Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application**.

Then build, install to `/Applications`, and launch:

```bash
pkill -x Drobu 2>/dev/null; ./build.sh --install && open /Applications/Drobu.app
```

If the Developer ID cert is missing, the build **fails loudly** rather than falling back to ad-hoc signing — ad-hoc rotates the binary hash (revoking TCC grants every build) and breaks Sparkle updates for installed users. This is a single-maintainer commercial app; building a signed copy requires that maintainer's Developer ID cert.

## Tests

```bash
swift test
```

CI enforces this on every PR. Test targets live in `Tests/DrobuTests/` using Swift Testing (`@Test`, `@Suite`).

## License

Source is published for transparency and security audit. **All rights reserved** — Drobu is a commercial product; the compiled application is licensed separately. See [LICENSE](LICENSE).
