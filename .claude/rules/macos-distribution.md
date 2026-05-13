# macOS App Distribution

## DMG layout: `hdiutil` alone is flat; use `create-dmg` for the drag-to-Applications UX

A bare `hdiutil create -srcfolder Drobu.app -ov -format UDZO out.dmg` produces a working DMG, but opening it shows a basic Finder window with just the `.app` icon — no Applications shortcut, no window sizing, no icon positioning. That's the developer-tools UX (VS Code, iTerm ship like this). Consumer macOS apps almost always have the **drag-to-Applications** layout: app icon on the left, Applications-folder shortcut on the right, intentional window size.

The window layout is stored in the mounted volume's `.DS_Store` file and is set via AppleScript that talks to Finder. Doing this from raw bash is notoriously brittle (Finder events fire async, mount/unmount race conditions, scripting permission prompts).

**Use `create-dmg`** (the GitHub `create-dmg/create-dmg` Homebrew package, **not** Sindre Sorhus's Node one — same name, different tool):

```bash
brew install create-dmg

create-dmg \
    --volname "Drobu" \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "Drobu.app" 130 180 \
    --app-drop-link 410 180 \
    --hide-extension "Drobu.app" \
    Drobu.dmg \
    .build/Drobu.app
```

What each flag does:
- `--volname` — mounted volume name (shows in Finder sidebar)
- `--window-size W H` — the Finder window dimensions
- `--icon-size N` — display size for app + folder shortcut icons
- `--icon "<name>" X Y` — position of the app inside the window
- `--app-drop-link X Y` — creates the `/Applications` symlink at the given coordinates
- `--hide-extension "<name>"` — Finder shows "Drobu" not "Drobu.app"

The signed `.app` inside the DMG is what Sparkle / Gatekeeper verifies. The DMG itself doesn't need an EdDSA signature for Sparkle — the appcast hashes the entire DMG and verifies that hash via `sparkle:edSignature`.

## Sparkle appcast for DMG enclosures

Switch the `<enclosure type>` from `application/octet-stream` (used for `.zip`) to `application/x-apple-diskimage`. Sparkle clients then know to mount the disk image and copy the `.app` out, rather than unzipping.

## Code-signing the DMG itself

Optional for self-signed dev workflows; required for Apple Developer ID distribution. The signed `.app` inside the DMG is what matters for Gatekeeper; the outer DMG is signed only to prevent in-transit tampering of the container.

## Don't use `cp -r` for `.app` bundles

`Drobu.app/Contents/Frameworks/Sparkle.framework/Versions/Current` is a symlink to `Versions/B`. `cp -r` doesn't preserve symlinks correctly on macOS — the result is two directories instead of a directory + symlink, which breaks code signing and runtime framework lookup.

**Always use `ditto` for `.app` bundles:**
```bash
ditto "$APP_BUNDLE" "/Applications/${APP_NAME}.app"
ditto -c -k --keepParent Drobu.app Drobu.zip
```

`ditto` preserves symlinks, resource forks, and metadata correctly. `create-dmg` internally uses `ditto`, so the DMG path is safe; only matters when you copy the `.app` yourself.

## Stable "latest" download URLs

GitHub Releases serves `https://github.com/<owner>/<repo>/releases/latest/download/<filename>` as a redirect to whatever the newest release's asset of that exact name is. **Asset filenames must match exactly** — `Drobu.dmg` and `Drobu-1.2.dmg` are different URLs.

Keep release asset filenames **un-versioned** so the website's Download CTA can point at a single stable URL and never needs editing across releases:

```bash
DMG="Drobu.dmg"   # not Drobu-$VERSION.dmg
```

The release tag (e.g., `v1.2`) provides the version axis; the filename should not.
