# Sparkle macOS Gotchas

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
