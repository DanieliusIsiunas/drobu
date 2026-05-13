#!/usr/bin/env bash
# One-shot: generate the Ed25519 keypair used to sign Drobu license keys.
#
# What it does:
#   1. Generates a fresh Ed25519 keypair via openssl.
#   2. Stores the private key in your login Keychain as a generic password
#      (account: drobu-license-ed25519). issue-license-key.sh reads it back
#      from here.
#   3. Prints the base64-encoded raw 32-byte public key. Paste this into
#      Sources/DrobuCore/Info.plist under the DrobuLicensePublicKey key.
#
# Safety rails:
#   - Aborts if a private key with the same account already exists in
#     Keychain (refuses to clobber). Use --force to override.
#   - The private key NEVER touches the filesystem. openssl writes it to
#     a temp file in the user's home which is wiped immediately after
#     import to Keychain.
#
# Run once per project lifetime. Then commit the updated Info.plist.

set -euo pipefail

ACCOUNT="drobu-license-ed25519"
SERVICE="com.danielius.ClipboardHistory.license-signing"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# Bail if already present and --force not passed.
if security find-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null 2>&1; then
    if [[ $FORCE -ne 1 ]]; then
        echo "✗ A license-signing key already exists in Keychain (account: $ACCOUNT)."
        echo "  Re-running would clobber it and invalidate every license you've ever issued."
        echo "  If you really mean to regenerate, pass --force."
        exit 1
    fi
    echo "! --force given — removing the existing entry."
    security delete-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null
fi

# Generate the keypair using Swift CryptoKit (the same framework the app
# uses to verify keys at runtime — guarantees the private+public encodings
# are byte-compatible with what LicenseManager expects). LibreSSL on macOS
# ships without Ed25519 support, so openssl is not an option here.
#
# Output is two newline-separated base64 strings: private (32 raw bytes)
# then public (32 raw bytes).
KEYPAIR=$(swift -e '
import CryptoKit
let priv = Curve25519.Signing.PrivateKey()
print(priv.rawRepresentation.base64EncodedString())
print(priv.publicKey.rawRepresentation.base64EncodedString())
')
PRIV_B64=$(echo "$KEYPAIR" | sed -n '1p')
PUB_B64=$(echo "$KEYPAIR" | sed -n '2p')

if [[ -z $PRIV_B64 || -z $PUB_B64 ]]; then
    echo "✗ Swift keypair generation failed:" >&2
    echo "$KEYPAIR" >&2
    exit 1
fi

# Store the private key (base64, 44 chars) in Keychain.
security add-generic-password \
    -a "$ACCOUNT" \
    -s "$SERVICE" \
    -w "$PRIV_B64" \
    -j "Ed25519 private key (base64, 32 raw bytes) used to sign Drobu license keys. Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not share." \
    -U

unset PRIV_B64 KEYPAIR

echo
echo "✓ Keypair generated."
echo "  Account:        $ACCOUNT"
echo "  Service:        $SERVICE"
echo "  Storage:        login Keychain"
echo
echo "PUBLIC KEY (base64 raw 32-byte Ed25519):"
echo
echo "  $PUB_B64"
echo
echo "Next steps:"
echo "  1. Paste the public key above into Sources/DrobuCore/Info.plist:"
echo
echo "     <key>DrobuLicensePublicKey</key>"
echo "     <string>$PUB_B64</string>"
echo
echo "  2. Commit the Info.plist change."
echo "  3. Run tools/issue-license-key.sh <email> to mint per-customer keys."
echo
echo "  The private key stays in your login Keychain. It is NOT in the repo,"
echo "  NOT in CI, and NEVER on disk after this script exits. Back it up via"
echo "  Keychain Access > File > Export Items if you want a recovery copy."
