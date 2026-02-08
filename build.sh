#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClipboardHistory"
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

# Code signing: use a stable self-signed certificate so Accessibility permission persists across rebuilds.
# Ad-hoc signing (codesign --sign -) generates a unique hash per build, which invalidates TCC grants.
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Signing with certificate: $CERT_NAME"
    codesign --force --sign "$CERT_NAME" "$APP_BUNDLE"
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
    codesign --force --sign - "$APP_BUNDLE"

    # Only reset TCC when using ad-hoc signing, since the signature changes every build.
    # With a stable certificate, permission persists — that's the whole point.
    echo "Resetting Accessibility permission (ad-hoc signing invalidates it)..."
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
fi

echo ""
echo "Built: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE /Applications/"
