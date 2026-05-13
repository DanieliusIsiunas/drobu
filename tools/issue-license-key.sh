#!/usr/bin/env bash
# Mint a single Drobu license key for a customer.
#
# Usage: ./tools/issue-license-key.sh <customer-email>
#
# Workflow:
#   1. Reads the Ed25519 private key from your login Keychain
#      (account: drobu-license-ed25519). Run generate-license-keypair.sh
#      once before this script.
#   2. Generates 32 random bytes as the license payload.
#   3. Signs the payload with the private key using CryptoKit.
#   4. Prints the key in `DROBU-<base64url(payload)>.<base64url(sig)>` form.
#   5. Appends a row to tools/license-log.csv with timestamp + email +
#      payload-hex so you have an audit trail for support / revocations.
#
# Copy the printed key into an email to the customer.
#
# The private key never leaves your Keychain. The customer-side app
# verifies the signature offline against the embedded public key —
# no server, no internet, no phone-home.

set -euo pipefail

cd "$(dirname "$0")/.."

ACCOUNT="drobu-license-ed25519"
SERVICE="com.danielius.ClipboardHistory.license-signing"
LOG="tools/license-log.csv"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <customer-email>" >&2
    exit 1
fi
EMAIL="$1"

# Pull the private key (base64, 32 raw bytes) from Keychain.
PRIV_B64=$(security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null) || {
    echo "✗ Private key not found in Keychain (account: $ACCOUNT)." >&2
    echo "  Run tools/generate-license-keypair.sh first." >&2
    exit 1
}

# Sign in Swift — same framework the app verifies with, so the bytes are
# guaranteed compatible. Outputs two newline-separated base64url strings:
# the random payload then the 64-byte signature.
OUT=$(swift -e "
import CryptoKit
import Foundation

guard let privData = Data(base64Encoded: \"$PRIV_B64\") else {
    FileHandle.standardError.write(\"Failed to decode private key.\\n\".data(using: .utf8)!)
    exit(1)
}
let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)

var payload = Data(count: 32)
let result = payload.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, \$0.baseAddress!) }
guard result == errSecSuccess else {
    FileHandle.standardError.write(\"Random bytes failed.\\n\".data(using: .utf8)!)
    exit(1)
}

let sig = try priv.signature(for: payload)

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
     .replacingOccurrences(of: \"+\", with: \"-\")
     .replacingOccurrences(of: \"/\", with: \"_\")
     .replacingOccurrences(of: \"=\", with: \"\")
}

print(b64url(payload))
print(b64url(sig))
print(payload.map { String(format: \"%02x\", \$0) }.joined())
")

PAYLOAD_B64URL=$(echo "$OUT" | sed -n '1p')
SIG_B64URL=$(echo "$OUT" | sed -n '2p')
PAYLOAD_HEX=$(echo "$OUT" | sed -n '3p')

if [[ -z $PAYLOAD_B64URL || -z $SIG_B64URL ]]; then
    echo "✗ Signing failed:" >&2
    echo "$OUT" >&2
    exit 1
fi

KEY="DROBU-${PAYLOAD_B64URL}.${SIG_B64URL}"

# Append to the audit log.
if [[ ! -f $LOG ]]; then
    echo "timestamp,email,payload_hex" > "$LOG"
fi
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$EMAIL,$PAYLOAD_HEX" >> "$LOG"

# Output.
echo
echo "✓ License key minted for $EMAIL"
echo
echo "  $KEY"
echo
echo "Copy the key above and email it to the customer."
echo "Logged in $LOG (gitignored)."
