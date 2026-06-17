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

## Migrating signing identity (self-signed → Developer ID) is safe IF the EdDSA key is unchanged

As of v1.4.1 the app moved from the self-signed `ClipboardHistoryDev` cert to a **Developer ID Application** cert (Team `TGL69S88MD`) so releases can be notarized (v1.4 and earlier shipped self-signed). The scary question was: will installed clients signed with the *old* identity accept an update signed with the *new* one? Answer — verified against Sparkle 2.9.1 source (`.build/checkouts/Sparkle/Sparkle/SUUpdateValidator.m`): **yes, as long as the EdDSA key does not change.**

The validation gate in `SUUpdateValidator` is `passedDSACheck || passedCodeSigning` (an OR). The EdDSA signature is verified against the **old (installed) app's** `SUPublicEDKey`, and a valid EdDSA signature alone authorizes the update — Sparkle explicitly tolerates a code-signing identity change in this case (its own test `testPostValidationWithKeyRotation` covers "change the cert, keep the EdDSA key"). The new app must still be code signed (can't go signed→unsigned) and internally valid, which Developer ID + notarization satisfies.

**One-time re-auth prompts after the identity switch (expected, not a bug):** macOS binds both TCC grants and Keychain-item ACLs to the app's *code signature*. When an installed self-signed build updates (over Sparkle) to the Developer-ID build, the new signature is a "different app" to those subsystems, so the user sees one-time prompts:
- **Keychain:** *"Drobu wants to use your confidential information stored in `com.danielius.ClipboardHistory.license`"* — the license/trial data (accounts `trial-start`, and `active-license` if present) was written under the old identity. Click **Always Allow** (enter login password) to rewrite the ACL to trust the Developer ID signature. May appear once per account. **Never Deny** — that blocks Drobu from reading its own trial/license state and can throw the user into the activation gate.
- **Accessibility (TCC):** the Cmd+V paste grant may need re-granting once for the same reason.

This hits only installs that previously ran a self-signed build (1.2–1.4). **Fresh 1.4.1 installs never see it** — their Keychain items and TCC grants are born under Developer ID. It's the unavoidable, one-time cost of the identity migration; after Always Allow it's silent forever.

**Hard rules for the migration:**
- **Never change `SUPublicEDKey`.** It's the unbroken chain of trust across the identity switch. Ours: `XmiKqgGJ6dSmGbT3ehj6B9IUkn87vRhKbe16rTWGP54=`. `release.sh` signs the DMG with the matching private key from Keychain — same keypair.
- **Never rotate the EdDSA key AND the signing cert in the same release** — that breaks the chain and Sparkle rejects with "signed with a new Code Signing identity that doesn't match…".
- The error people hit historically ("identity changed → refuses update") is either signed→**unsigned** (always rejected) or an identity change with **no valid EdDSA** (DSA-only, or `SUVerifyUpdateBeforeExtraction` set). We have neither: EdDSA is valid and `SUVerifyUpdateBeforeExtraction` is unset.
- The team-ID-match fallback (`codeSignatureIsValidAtDownloadURL:andMatchesDeveloperIDTeamFromOldBundleURL:`) bails for a no-team host — but it's only consulted when EdDSA *fails*, so it never gates us.

## Notarization requires hardened runtime + secure timestamp on ALL nested code

`codesign --options runtime` (hardened runtime) AND `--timestamp` (secure timestamp) are both mandatory for notarization, and must be applied to every nested executable — the Sparkle XPC services, `Autoupdate`, `Updater.app`, the framework, and the outer app. Missing `--timestamp` is a silent local success that Apple's notary service rejects. `build.sh` adds both to every `codesign` call. Verify a build is notarization-ready before submitting:
```bash
codesign -dvvv .build/Drobu.app 2>&1 | grep -E 'Timestamp|flags|TeamIdentifier'  # want Timestamp set, flags=0x10000(runtime)
codesign --verify --deep --strict --verbose=2 .build/Drobu.app                    # "satisfies its Designated Requirement"
```

## Self-signed cert requires `disable-library-validation`

**(Superseded by the Developer ID migration above — kept for history / if the app ever reverts to self-signing.)**


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

**(Superseded by the Developer ID migration above — `build.sh` no longer uses `ClipboardHistoryDev` and no longer has an ad-hoc fallback; it now hard-fails if the Developer ID cert is missing. Kept for history / if the app ever reverts to self-signing.)**

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

## Gentle update reminders (v1.9.1): suppress the modal for a menu-bar app

Drobu is `.accessory` (no dock icon), so Sparkle's default modal-on-background-check
is jarring. The fix is Sparkle's documented **gentle reminders** (≥2.2):
`AppDelegate` is the `SPUStandardUserDriverDelegate`, surfacing a waiting update
via status-menu items + a status-icon glyph instead of a modal. Three traps,
all learned the hard way:

- **`SPUStandardUserDriverDelegate` is NOT `@MainActor`.** Conforming a
  `@MainActor` class to it fails the Swift 6 build with *"conformance … crosses
  into main actor-isolated code"* (`#ConformanceIsolation`). Fix: declare every
  witness `nonisolated` and hop inside with `MainActor.assumeIsolated { … }`.
  `assumeIsolated` is safe because Sparkle 2.9.1 invokes all of these on the main
  thread (the suppressed-update callback is dispatched to the main queue; the
  synchronous ones run inside main-thread-asserted driver methods). Do NOT mark
  the conformance with a fake `@MainActor` or move it to an actor — `nonisolated`
  + `assumeIsolated` is the pattern.

- **Gate the gentle UI on `!handleShowingUpdate`, not just `!state.userInitiated`.**
  `standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate:forUpdate:state:)`
  fires for *every* presented update, including the scheduled-but-immediate-focus
  path where Sparkle shows its OWN modal (`handleShowingUpdate == true`,
  `state.userInitiated == false`). Guarding only on `!state.userInitiated` lights
  the gentle indicator *behind* Sparkle's modal — a double presentation. Correct
  guard: `guard !state.userInitiated, !handleShowingUpdate else { return }` — only
  surface gentle UI when WE are handling the presentation (we suppressed the
  modal). `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`
  returns `immediateFocus`; note `immediateFocus` means *app launched recently OR
  system idle* (Sparkle's heuristic for "user is plausibly attentive"), NOT
  "frontmost" — so a scheduled check shortly after launch still shows the modal,
  by design.

- **`SUAutomaticallyUpdate=true` only pre-downloads; it never weakens the EdDSA
  gate.** Verified against `SUUpdateValidator.m` (`validateDownloadPath` gates
  install on `passedDSACheck || passedCodeSigning`, independent of the user-driver
  delegate and of whether the download was automatic). Suppressing the scheduled
  modal hides UI only — install still requires the user invoking
  `checkForUpdates(nil)` ("Restart to Update"), which routes through the same
  verified Install & Relaunch. Guard that menu action against a stale click
  (`pendingUpdateVersion == nil`) or it starts a fresh "Checking for Updates"
  modal — the exact thing the feature suppresses.
