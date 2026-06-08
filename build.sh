#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Drobu"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
BUNDLE_ID="com.danielius.ClipboardHistory"
# Sign with the Apple Developer ID Application cert so releases can be notarized
# and dev builds keep a stable signature (Accessibility permission persists).
# The cert name embeds the Team ID; resolved dynamically so a cert renewal
# (which keeps the same name) doesn't require editing this script.
CERT_NAME=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)

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
cp "$SCRIPT_DIR/Sources/DrobuCore/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

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

# Code signing: Developer ID Application cert + hardened runtime + secure timestamp.
# The stable Developer ID signature keeps Accessibility permission across rebuilds
# and lets release.sh notarize the same bundle. --timestamp is REQUIRED for
# notarization (Apple rejects ad-hoc-timestamped binaries).
ENTITLEMENTS="$SCRIPT_DIR/Sources/DrobuCore/Drobu.entitlements"

if [ -z "$CERT_NAME" ]; then
    echo ""
    echo "============================================================"
    echo "  DEVELOPER ID APPLICATION CERTIFICATE NOT FOUND"
    echo "============================================================"
    echo ""
    echo "  Build FAILED — refusing to fall back to ad-hoc signing."
    echo ""
    echo "  Ad-hoc signing changes the app's identity every build, which"
    echo "  resets Accessibility permission and — critically — breaks"
    echo "  Sparkle updates for installed users (this cost us a v1.2 redo)."
    echo ""
    echo "  The Developer ID cert should be in your login Keychain. Check:"
    echo "    security find-identity -v -p codesigning"
    echo ""
    echo "  If it's missing: Xcode > Settings > Accounts > Manage"
    echo "  Certificates > + > Developer ID Application. If present but not"
    echo "  listed as valid, its trust may have drifted — see"
    echo "  .claude/rules/sparkle-macos-gotchas.md."
    echo ""
    echo "============================================================"
    exit 1
fi

echo "Signing with certificate: $CERT_NAME (hardened runtime + timestamp)"
# Sign Sparkle components inside-out (never use --deep)
find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B" \
    \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
    -exec codesign --force --sign "$CERT_NAME" --options runtime --timestamp {} \;
codesign --force --sign "$CERT_NAME" --options runtime --timestamp \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
# Sign the app bundle last (with entitlements)
codesign --force --sign "$CERT_NAME" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

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
