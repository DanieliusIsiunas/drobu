# Sparkle macOS Gotchas

## Repo rename strands installed clients on a dead appcast URL

`SUFeedURL` is baked into each shipped app's Info.plist. When the repo was renamed `clipboard-history` → `drobu` (commit `a3c2bd3`), the GitHub Pages URL changed with it — and **GitHub Pages does NOT redirect after a rename** (git remotes and `releases/download/...` URLs do; Pages 404s). Every install whose baked-in feed URL predates the rename silently stops seeing updates: Sparkle's background check treats an appcast load failure as "no update available" — no error UI, `SULastCheckTime` keeps advancing as if everything works.

Affected here: v1.2 (build 3) was the only release shipped with the old `/clipboard-history/appcast.xml` URL; v1.3+ already pointed at `/drobu/appcast.xml`.

**Diagnose:** compare the installed app's feed against the live appcast:
```bash
plutil -extract SUFeedURL raw /Applications/Drobu.app/Contents/Info.plist
curl -sL -o /dev/null -w '%{http_code}\n' "$(plutil -extract SUFeedURL raw /Applications/Drobu.app/Contents/Info.plist)"
```
A 404 means that install can never auto-update — it needs a manual reinstall (or a forwarding appcast resurrected at the old URL, e.g. a stub repo with the old name serving only `appcast.xml`).

**Rule:** treat `SUFeedURL` as a permanent public contract. Never rename the repo/Pages path that hosts the appcast without first standing up a permanent forward at the old URL. Prefer a custom domain you control over a `github.io/<repo-name>/` path for the feed.

## Self-signed cert requires `disable-library-validation`

Even when re-signing all Sparkle.framework components with `--force --sign "$CERT_NAME"` (inside-out), a self-signed certificate (like `ClipboardHistoryDev`) still fails hardened runtime's Library Validation. The `com.apple.security.cs.disable-library-validation` entitlement is required.

This can be removed once the app is signed with an Apple Developer ID certificate.

## Framework embedding with `swift build`

SPM binary targets (like Sparkle's XCFramework) are NOT automatically embedded in the app bundle by `swift build`. Must manually:
1. `ditto` the framework from `.build/artifacts/` into `Contents/Frameworks/`
2. Add `@executable_path/../Frameworks` rpath via `install_name_tool`
3. Sign inside-out: nested code first, framework second, app bundle last

## `ditto` not `cp -r` for frameworks

Sparkle.framework uses internal symlinks (`Versions/Current -> B`). `cp -r` breaks them, which breaks code signing. Always use `ditto` for copying frameworks — including the `--install` path to `/Applications/`.

## Inside-out code signing

Use `find`-based signing for Sparkle internals to be future-proof against structure changes:
```bash
find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" \
    \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
    -exec codesign --force --sign "$CERT_NAME" --options runtime {} \;
```
Never use `--deep`. Never pass `--entitlements` to Sparkle sub-components (only to the outer app bundle).

## Self-signed cert trust drifts; `build.sh` silently falls back to ad-hoc

A self-signed `ClipboardHistoryDev` certificate in the login Keychain can be *present* but *not trusted for code signing* — `security find-identity -v -p codesigning` then returns "0 valid identities" even though `security find-certificate -c ClipboardHistoryDev` succeeds. The trust state can clear unexpectedly (likely after sleep / Keychain lock cycles or macOS updates).

**Symptom in `build.sh`:**
```
============================================================
  CERTIFICATE NOT FOUND: ClipboardHistoryDev
============================================================
…
Falling back to ad-hoc signing (permission will reset each build)...
```

This is **silent disaster** for releases: the produced `Drobu.zip` / `Drobu.dmg` has an ad-hoc-signed app whose identity differs from previously-installed builds. Sparkle's update flow refuses the update because the signing identity changed — installed customers cannot upgrade.

**Diagnose:**
```bash
# Cert exists?
security find-certificate -c "ClipboardHistoryDev" -p ~/Library/Keychains/login.keychain-db

# But is it trusted?
security find-identity -p codesigning   # full list (may show CSSMERR_TP_NOT_TRUSTED)
security find-identity -v -p codesigning # valid only
```

If the cert appears in the full list with `CSSMERR_TP_NOT_TRUSTED` but not in `-v`, that's exactly this state.

**Fix (UI only — `security set-trust-settings` is interactive-auth-only):**

1. Open **Keychain Access.app**
2. Left sidebar → **login** → **My Certificates** → double-click `ClipboardHistoryDev`
3. Expand the **▶ Trust** disclosure
4. Set **"When using this certificate"** → **Always Trust**
5. Close window → Touch ID / password to authorize

Then re-verify: `security find-identity -v -p codesigning` should show **1 valid identity**.

**Harden `build.sh`** by making the fallback loud (fail the build instead of silently ad-hoc-signing). Worth doing before the next major release — the silent path cost us a v1.2 we had to undo and redo.
