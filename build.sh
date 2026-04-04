#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Drobu"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
BUNDLE_ID="com.danielius.ClipboardHistory"
CERT_NAME="ClipboardHistoryDev"

echo "Building ${APP_NAME}..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/release/${APP_NAME}" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "$SCRIPT_DIR/Sources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy menu bar icon (template image — "Template" suffix tells macOS to auto-tint)
cp "$SCRIPT_DIR/Resources/MenuBarIconTemplate.png" "$APP_BUNDLE/Contents/Resources/MenuBarIconTemplate.png"
cp "$SCRIPT_DIR/Resources/MenuBarIconTemplate@2x.png" "$APP_BUNDLE/Contents/Resources/MenuBarIconTemplate@2x.png"

# Embed Sparkle framework (SPM binary target — must be manually copied)
SPARKLE_FRAMEWORK=$(find "$BUILD_DIR/artifacts" -path "*/macos-arm64_x86_64/Sparkle.framework" -type d | head -1)
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework not found in .build/artifacts. Run 'swift package resolve' first."
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Set rpath so executable finds the framework at runtime (guard against duplicates)
if ! otool -l "$APP_BUNDLE/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
fi

# Code signing: use a stable self-signed certificate so Accessibility permission persists across rebuilds.
# Ad-hoc signing (codesign --sign -) generates a unique hash per build, which invalidates TCC grants.
ENTITLEMENTS="$SCRIPT_DIR/Sources/Drobu.entitlements"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Signing with certificate: $CERT_NAME (hardened runtime)"
    # Sign Sparkle components inside-out (never use --deep)
    find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B" \
        \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
        -exec codesign --force --sign "$CERT_NAME" --options runtime {} \;
    codesign --force --sign "$CERT_NAME" --options runtime \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    # Sign the app bundle last (with entitlements)
    codesign --force --sign "$CERT_NAME" --options runtime --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
else
    echo ""
    echo "============================================================"
    echo "  CERTIFICATE NOT FOUND: $CERT_NAME"
    echo "============================================================"
    echo ""
    echo "  A stable code-signing certificate is needed so that"
    echo "  Accessibility permission persists across rebuilds."
    echo ""
    echo "  ONE-TIME SETUP (takes 30 seconds):"
    echo ""
    echo "  1. Open Keychain Access.app"
    echo "  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate..."
    echo "  3. Name:  $CERT_NAME"
    echo "     Identity Type:  Self-Signed Root"
    echo "     Certificate Type:  Code Signing"
    echo "  4. Click Create, then Done."
    echo "  5. Re-run this build script."
    echo ""
    echo "============================================================"
    echo ""
    echo "Falling back to ad-hoc signing (permission will reset each build)..."
    # Sign Sparkle components inside-out (never use --deep)
    find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B" \
        \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
        -exec codesign --force --sign - --options runtime {} \;
    codesign --force --sign - --options runtime \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    # Sign the app bundle last (with entitlements)
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

    # Only reset TCC when using ad-hoc signing, since the signature changes every build.
    # With a stable certificate, permission persists — that's the whole point.
    echo "Resetting Accessibility permission (ad-hoc signing invalidates it)..."
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
fi

echo ""
echo "Built: $APP_BUNDLE"

for arg in "$@"; do
    case "$arg" in
        --install)
            echo "Installing to /Applications..."
            rm -rf "/Applications/ClipboardHistory.app"  # one-time cleanup of old name
            rm -rf "/Applications/${APP_NAME}.app"
            ditto "$APP_BUNDLE" "/Applications/${APP_NAME}.app"
            echo "Installed: /Applications/${APP_NAME}.app"
            ;;
        --dmg)
            DMG_PATH="$BUILD_DIR/${APP_NAME}.dmg"
            rm -f "$DMG_PATH"
            hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" \
                -ov -format UDZO "$DMG_PATH"
            echo "Created: $DMG_PATH"
            ;;
        --notarize)
            # Requires Apple Developer ID certificate ($99/yr).
            # One-time setup: xcrun notarytool store-credentials "notary-profile"
            echo "Creating zip for notarization..."
            ditto -c -k --keepParent "$APP_BUNDLE" "$BUILD_DIR/${APP_NAME}.zip"
            echo "Submitting for notarization..."
            xcrun notarytool submit "$BUILD_DIR/${APP_NAME}.zip" \
                --keychain-profile "notary-profile" --wait
            echo "Stapling..."
            xcrun stapler staple "$APP_BUNDLE"
            echo "Notarization complete."
            ;;
    esac
done
