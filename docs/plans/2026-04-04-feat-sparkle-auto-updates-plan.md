---
title: "feat: Integrate Sparkle Auto-Updates"
type: feat
date: 2026-04-04
---

# feat: Integrate Sparkle Auto-Updates

## Overview

Add Sparkle 2.x auto-update support so users receive updates automatically. This is the top remaining blocker for commercial distribution — without it, users have no way to get fixes or new features after initial install.

Sparkle 2 distributes via SPM as a pre-built XCFramework (binary target). Since Drobu uses `swift build` + manual bundle assembly (not Xcode), integration requires explicit framework embedding, inside-out code signing, and rpath setup in `build.sh`.

## Problem Statement

Users who download Drobu have no update path. If a critical bug is fixed or a feature is added, they must manually find and re-download the app. This is unacceptable for a paid product — auto-updates are table stakes.

## Proposed Solution

Integrate `SPUStandardUpdaterController` from Sparkle 2.x with:
- Automatic daily background checks (Sparkle default)
- "Check for Updates..." in the status bar menu
- EdDSA-signed update archives hosted on GitHub Releases
- Appcast XML served from `website/public/appcast.xml` via existing GitHub Pages

## Prerequisites (One-Time Setup)

### EdDSA Key Generation

Run after first `swift build` (so SPM has downloaded Sparkle):

```bash
# Locate the generate_keys tool (path varies by SPM version)
GENERATE_KEYS=$(find .build/artifacts -name "generate_keys" -type f | head -1)
$GENERATE_KEYS
```

This creates an Ed25519 private key in the login Keychain and prints the base64 public key to stdout. Copy the public key into `Sources/Info.plist` as `SUPublicEDKey`.

**Back up the private key** (critical — lose this and you can never publish a signed update):

```bash
$GENERATE_KEYS -x sparkle_private_key
# Store sparkle_private_key somewhere safe (NOT in the repo)
```

Add `sparkle_private_key` to `.gitignore`.

## Technical Approach

### Phase 1: Build Infrastructure

This phase covers SPM dependency, framework embedding, code signing, entitlements, and Info.plist — all done as a single atomic commit since none of these work without the others.

#### 1a. SPM Dependency

**`Package.swift`** — add Sparkle:

```swift
// Package.swift:9-12
dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
],

// Package.swift:16-19
dependencies: [
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "HotKey", package: "HotKey"),
    .product(name: "Sparkle", package: "Sparkle"),
],
```

#### 1b. Framework Embedding in `build.sh`

After creating the bundle (after line 18), embed the framework:

```bash
# Embed Sparkle framework (SPM binary target — must be manually copied)
# Path varies by SPM version — discover it dynamically
SPARKLE_FRAMEWORK=$(find .build/artifacts -path "*/macos-arm64_x86_64/Sparkle.framework" -type d | head -1)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework not found in .build/artifacts. Run 'swift build' first."
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Set rpath so executable finds the framework at runtime (guard against duplicates)
if ! otool -l "$APP_BUNDLE/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
fi
```

**Why `ditto`:** Sparkle.framework uses internal symlinks (`Versions/Current -> B`). `cp -r` breaks them, which breaks code signing. `ditto` preserves symlinks.

**Also fix `--install` path** (line 79): change `cp -r` to `ditto` so symlinks survive installation to `/Applications/`:

```bash
# Was: cp -r "$APP_BUNDLE" "/Applications/${APP_NAME}.app"
ditto "$APP_BUNDLE" "/Applications/${APP_NAME}.app"
```

#### 1c. Inside-Out Code Signing

The current `build.sh` signs the entire bundle in one `codesign` call (line 39). With an embedded framework, signing must happen inside-out — nested code first, then the outer bundle. Never use `--deep`.

Use `find`-based signing to be future-proof against Sparkle internal structure changes:

```bash
# Sign all nested code inside Sparkle.framework (inside-out)
find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" \
    \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
    -exec codesign --force --sign "$CERT_NAME" --options runtime {} \;

# Sign the framework itself
codesign --force --sign "$CERT_NAME" --options runtime \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Sign the app bundle last (with entitlements)
codesign --force --sign "$CERT_NAME" --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
```

Same pattern for the ad-hoc fallback path (replace `$CERT_NAME` with `-`).

**Note on `disable-library-validation`:** Since we re-sign all Sparkle components with `--force` using `ClipboardHistoryDev`, all code in the bundle shares the same signing identity. Library Validation should pass without the `com.apple.security.cs.disable-library-validation` entitlement. **Try without it first.** Only add it to `Sources/Drobu.entitlements` if runtime testing shows Sparkle fails to load:

```xml
<!-- Only add if needed after testing: -->
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

This entitlement weakens hardened runtime and complicates future notarization, so avoid it if possible.

#### 1d. Info.plist Changes

**`Sources/Info.plist`** — add Sparkle keys (before closing `</dict>`):

```xml
<key>SUFeedURL</key>
<string>https://danieliusisiunas.github.io/clipboard-history/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>GENERATED_PUBLIC_KEY_HERE</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

`SUEnableAutomaticChecks = YES` suppresses Sparkle's first-launch "Check for updates automatically?" dialog. For a paid product, auto-updates should be opt-out, not opt-in.

**`CFBundleVersion` strategy:** Currently hardcoded to `"1"`. Sparkle uses this for version comparison (must be strictly increasing). Bump it manually in `Info.plist` when releasing — same workflow as `CFBundleShortVersionString`. Add it to the "version hardcoded in N places" section of CLAUDE.md.

### Phase 2: App Integration

**`Sources/App/AppDelegate.swift`** — add updater controller:

```swift
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Initialized in applicationDidFinishLaunching for explicit timing control
    private var updaterController: SPUStandardUpdaterController?
    // ... existing properties ...

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ... existing init code ...

        // Start Sparkle auto-update checks
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // ... rest of setup ...
    }
}
```

Initializing in `applicationDidFinishLaunching` (not as a property default) avoids Swift 6 `@MainActor` isolation ambiguity with the ObjC initializer and gives explicit timing control.

**`setupStatusItem()`** (line 237) — add menu item between Preferences and Quit:

```swift
let menu = NSMenu()
menu.addItem(withTitle: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")

if let controller = updaterController {
    let checkForUpdatesItem = NSMenuItem(
        title: "Check for Updates...",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    checkForUpdatesItem.target = controller
    menu.addItem(checkForUpdatesItem)
}

menu.addItem(.separator())
menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
statusItem?.menu = menu
```

The `target` assignment enables automatic menu item validation — Sparkle disables the item while a check is in progress.

No "Check for Updates" in Settings. Menu bar apps conventionally place it in the status menu. This also avoids the documented `NSApp.delegate as? AppDelegate` returns nil gotcha in the Settings scene.

### Phase 3: Appcast + Release Workflow

**`website/public/appcast.xml`** — initial empty appcast (deploys automatically via existing GitHub Pages workflow):

```xml
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Drobu Updates</title>
        <!-- Items added by generate_appcast or manually per release -->
    </channel>
</rss>
```

**Release workflow:**

```bash
# 1. Bump CFBundleVersion in Sources/Info.plist (and CFBundleShortVersionString if needed)

# 2. Build and install
./build.sh --install

# 3. Create the update archive
ditto -c -k --sequesterRsrc --keepParent /Applications/Drobu.app .build/Drobu.zip

# 4. Sign the archive with EdDSA
SIGN_UPDATE=$(find .build/artifacts -name "sign_update" -type f | head -1)
$SIGN_UPDATE .build/Drobu.zip
# Output: sparkle:edSignature="..." length="..."

# 5. Upload Drobu.zip to a GitHub Release (gh release create v1.2 .build/Drobu.zip)

# 6. Add <item> to website/public/appcast.xml with the signature, push to deploy
```

Each appcast `<item>`:

```xml
<item>
    <title>Version 1.2</title>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>1.2</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <pubDate>Fri, 04 Apr 2026 12:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/DanieliusIsiunas/clipboard-history/releases/download/v1.2/Drobu.zip"
        sparkle:edSignature="BASE64_SIGNATURE_HERE"
        length="FILE_SIZE_BYTES"
        type="application/octet-stream" />
</item>
```

## Local Testing Strategy

Before the first real release, verify the full update cycle locally:

1. Build version A with `CFBundleVersion = 1`
2. Build version B with `CFBundleVersion = 2`, create the signed zip
3. Serve the appcast + zip from a local web server (`python3 -m http.server 8000`)
4. Temporarily set `SUFeedURL` to `http://localhost:8000/appcast.xml` in version A's Info.plist
5. Launch version A, click "Check for Updates...", verify the update dialog appears
6. Install the update, verify the app relaunches as version B
7. Verify Accessibility permission persists (same signing identity)
8. Verify Launch at Login persists (same bundle ID + path)

## Files Changed

| File | Change |
|------|--------|
| `Package.swift` | Add Sparkle dependency (2 lines) |
| `build.sh` | Framework embedding, inside-out signing, rpath, `ditto` for --install |
| `Sources/Info.plist` | Add SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks; bump CFBundleVersion per release |
| `Sources/Drobu.entitlements` | Add disable-library-validation (required — self-signed cert fails library validation even after re-signing) |
| `Sources/App/AppDelegate.swift` | Import Sparkle, init SPUStandardUpdaterController, add menu item |
| `website/public/appcast.xml` | New file — appcast feed |
| `.gitignore` | Add sparkle_private_key |

## Acceptance Criteria

- [x] App builds and launches with Sparkle framework embedded
- [x] "Check for Updates..." appears in the status bar menu
- [ ] Clicking "Check for Updates..." opens Sparkle's standard update dialog
- [ ] When no update is available, shows "You're up to date"
- [ ] Automatic background checks run without user interaction (no first-launch prompt)
- [ ] Appcast.xml is accessible at the GitHub Pages URL
- [ ] EdDSA keypair is generated and public key is in Info.plist
- [x] Code signing passes (`codesign --verify --deep --strict`)
- [ ] Accessibility (TCC) permission survives a rebuild (same cert = same identity)
- [ ] Launch at Login (SMAppService) survives an update (same bundle ID + path)
- [ ] Full update cycle tested locally (version A → version B)

## Edge Cases & Risks

**TCC preservation:** Same `ClipboardHistoryDev` signing identity across builds = TCC persists. If we ever switch to Developer ID, users re-grant once. Unavoidable.

**SMAppService:** Identified by bundle ID + install path. Both stay the same. Sparkle updates in-place.

**LSUIElement (no dock icon):** Sparkle 2.5+ handles `.accessory` apps natively. Update window appears without switching activation policy.

**Panel open during update:** Closes on app relaunch. Acceptable — Sparkle shows a "relaunch" prompt first.

**DB schema migration across updates:** Handled by GRDB migration chain in `AppDatabase`. Sparkle only replaces the binary — database in `~/Library/Application Support/` is untouched.

**Pre-Sparkle → Sparkle transition:** Users on the current version must manually download the first Sparkle-enabled build. All future updates are automatic. Post a note on the website.

**Gatekeeper quarantine:** Sparkle-installed updates are NOT quarantined (applied by a local process). No Gatekeeper warning on updated versions — only the initial install.

**Rollback:** If an update bricks the app, users download the previous version from GitHub Releases and replace `/Applications/Drobu.app`. Document this on the website's support/FAQ page.

## Dependencies & Prerequisites

- **Sparkle 2.x** — well-maintained, latest 2.9.1. Only new dependency.
- **One-time manual step:** Run `generate_keys` to create EdDSA keypair (see Prerequisites section)
- **Future:** Apple Developer ID ($99/yr) for notarization — separate task, not blocking Sparkle

## CLAUDE.md Updates

Add `CFBundleVersion` to the versioning section:

> **Version is hardcoded in 4 places — update all four:**
> 1. `Sources/Info.plist` — `CFBundleShortVersionString` (display version, e.g., "1.2")
> 2. `Sources/Info.plist` — `CFBundleVersion` (build number, incrementing integer for Sparkle)
> 3. `Sources/Views/SettingsView.swift` — version text in About section
> 4. `website/src/components/DownloadCTA.astro` — version in download CTA
> 5. `website/src/components/Footer.astro` — version in footer

## References

- [Sparkle Official Docs](https://sparkle-project.org/documentation/)
- [Sparkle Programmatic Setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle Publishing Updates](https://sparkle-project.org/documentation/publishing/)
- [Sparkle GitHub](https://github.com/sparkle-project/Sparkle)
- `build.sh:16-39` — current bundle assembly + signing
- `Sources/App/AppDelegate.swift:237-241` — current menu setup
- `Sources/Info.plist:11-14` — current version keys
- `.claude/rules/swiftui-macos-gotchas.md` — Button/Form and NSApp.delegate gotchas
