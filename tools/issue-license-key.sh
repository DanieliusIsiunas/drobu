#!/usr/bin/env bash
# Mint a single Drobu license key for a customer (the MANUAL fallback to the
# automated Stripe-webhook fulfillment).
#
# Usage: ./tools/issue-license-key.sh <customer-email> [--session <cs_...>]
#
# Workflow:
#   1. Reads the Ed25519 private key from your login Keychain
#      (account: drobu-license-ed25519). Run generate-license-keypair.sh
#      once before this script.
#   2. Generates 32 random bytes as the license payload.
#   3. Signs the payload with the private key using CryptoKit (the key
#      crosses into swift via the environment, never interpolated into
#      ps-visible source text).
#   4. Prints the key in `DROBU-<base64url(payload)>.<base64url(sig)>` form.
#   5. Appends a row to tools/license-log.csv with timestamp + email +
#      payload-hex so you have an audit trail for support / revocations.
#
# --session <cs_...>: when hand-fulfilling a SPECIFIC Stripe purchase (e.g.
# after a webhook outage), pass the checkout session id. The script then:
#   * FIRST checks the Supabase pool for an existing claim on that session —
#     if one exists it prints THAT key and mints nothing (one payment must
#     never yield two keys);
#   * otherwise it records the hand-minted key as a claimed row upstream, so
#     a later webhook retry for the same session returns this same key
#     instead of burning a pool key.
# Without --session the script works fully offline, exactly as before.
#
# Copy the printed key into an email to the customer.
#
# The private key never leaves your Keychain. The customer-side app
# verifies the signature offline against the embedded public key —
# no server, no internet, no phone-home.

set -euo pipefail

cd "$(dirname "$0")/.."

# Temp files in the --session path hold key strings — owner-only at birth.
umask 0077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ACCOUNT="drobu-license-ed25519"
SERVICE="com.danielius.ClipboardHistory.license-signing"
SR_ACCOUNT="drobu-supabase-service-role"
SR_SERVICE="com.danielius.ClipboardHistory.supabase"
LOG="tools/license-log.csv"
INFO_PLIST="Sources/DrobuCore/Info.plist"

EMAIL=""
SESSION_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)
            [[ $# -ge 2 ]] || { echo "✗ --session needs a value" >&2; exit 1; }
            SESSION_ID="$2"; shift 2 ;;
        -*)
            echo "Usage: $0 <customer-email> [--session <cs_...>]" >&2; exit 1 ;;
        *)
            if [[ -n $EMAIL ]]; then
                echo "Usage: $0 <customer-email> [--session <cs_...>]" >&2; exit 1
            fi
            EMAIL="$1"; shift ;;
    esac
done
if [[ -z $EMAIL ]]; then
    echo "Usage: $0 <customer-email> [--session <cs_...>]" >&2
    exit 1
fi

# --- Supabase context (only needed with --session) --------------------------
SUPABASE_URL=""
SR_KEY=""
if [[ -n $SESSION_ID ]]; then
    SUPABASE_URL="${DROBU_SUPABASE_URL:-}"
    if [[ -z $SUPABASE_URL && -f supabase/.temp/project-ref ]]; then
        REF=$(cat supabase/.temp/project-ref)
        SUPABASE_URL="https://${REF}.supabase.co"
    fi
    if [[ -z $SUPABASE_URL ]]; then
        echo "✗ --session needs the Supabase project (run 'supabase link' or set DROBU_SUPABASE_URL)." >&2
        exit 1
    fi
    SR_KEY=$(security find-generic-password -a "$SR_ACCOUNT" -s "$SR_SERVICE" -w 2>/dev/null) || {
        echo "✗ Supabase service-role key not in Keychain (account: $SR_ACCOUNT)." >&2
        exit 1
    }
    # Auth via curl config file: the key never appears on a ps-visible argv.
    printf 'header = "apikey: %s"\nheader = "Authorization: Bearer %s"\n' \
        "$SR_KEY" "$SR_KEY" > "$WORK/curl-headers"

    # One payment, one key: if this session already has a claim, print it.
    EXISTING_BODY="$WORK/existing.json"
    HTTP_CODE=$(curl -s -o "$EXISTING_BODY" -w '%{http_code}' \
        --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
        -K "$WORK/curl-headers" \
        "${SUPABASE_URL}/rest/v1/license_keys?stripe_session_id=eq.${SESSION_ID}&select=key") || HTTP_CODE=000
    if [[ $HTTP_CODE != 200 ]]; then
        echo "✗ Could not check the pool for session ${SESSION_ID} (HTTP $HTTP_CODE) — refusing to mint blind." >&2
        exit 1
    fi
    EXISTING_KEY=$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))
print(rows[0]["key"] if rows else "")' "$EXISTING_BODY")
    if [[ -n $EXISTING_KEY ]]; then
        echo
        echo "! Session ${SESSION_ID} already has a vended key — minting NOTHING."
        echo
        echo "  $EXISTING_KEY"
        echo
        echo "Send that key to the customer (it may already have been emailed)."
        exit 0
    fi
fi

# --- Mint -------------------------------------------------------------------
PRIV_B64=$(security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null) || {
    echo "✗ Private key not found in Keychain (account: $ACCOUNT)." >&2
    echo "  Run tools/generate-license-keypair.sh first." >&2
    exit 1
}

# Sign in Swift — same framework the app verifies with, so the bytes are
# guaranteed compatible. Outputs three newline-separated strings: the
# base64url payload, the base64url 64-byte signature, then the payload hex.
OUT=$(DROBU_PRIV_B64="$PRIV_B64" swift -e '
import CryptoKit
import Foundation

guard let privB64 = ProcessInfo.processInfo.environment["DROBU_PRIV_B64"],
      let privData = Data(base64Encoded: privB64) else {
    FileHandle.standardError.write("Failed to read private key from environment.\n".data(using: .utf8)!)
    exit(1)
}
let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)

var payload = Data(count: 32)
let result = payload.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
guard result == errSecSuccess else {
    FileHandle.standardError.write("Random bytes failed.\n".data(using: .utf8)!)
    exit(1)
}

let sig = try priv.signature(for: payload)

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
     .replacingOccurrences(of: "+", with: "-")
     .replacingOccurrences(of: "/", with: "_")
     .replacingOccurrences(of: "=", with: "")
}

print(b64url(payload))
print(b64url(sig))
print(payload.map { String(format: "%02x", $0) }.joined())
')
unset PRIV_B64

PAYLOAD_B64URL=$(echo "$OUT" | sed -n '1p')
SIG_B64URL=$(echo "$OUT" | sed -n '2p')
PAYLOAD_HEX=$(echo "$OUT" | sed -n '3p')

if [[ -z $PAYLOAD_B64URL || -z $SIG_B64URL ]]; then
    echo "✗ Signing failed:" >&2
    echo "$OUT" >&2
    exit 1
fi

KEY="DROBU-${PAYLOAD_B64URL}.${SIG_B64URL}"

# --- Record the claim upstream (--session only) ------------------------------
# Deliberately NOT the claim_license_key RPC: that vends from the pool, but
# this key was freshly minted OUTSIDE the pool — calling the RPC would burn a
# pool key AND leave this one unrecorded. A direct insert of an
# already-claimed row is the correct shape for the manual path.
if [[ -n $SESSION_ID ]]; then
    KEY_VERSION=$(plutil -extract DrobuLicensePublicKey raw "$INFO_PLIST" | base64 -d | shasum -a 256 | cut -c1-8)
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Key material reaches python via env, and curl via a body file — never
    # a ps-visible argv.
    DROBU_K="$KEY" DROBU_H="$PAYLOAD_HEX" DROBU_V="$KEY_VERSION" \
    DROBU_T="$NOW" DROBU_S="$SESSION_ID" DROBU_E="$EMAIL" python3 -c '
import json, os
e = os.environ
print(json.dumps({
    "key": e["DROBU_K"], "payload_hex": e["DROBU_H"], "key_version": e["DROBU_V"],
    "minted_at": e["DROBU_T"], "claimed_at": e["DROBU_T"],
    "stripe_session_id": e["DROBU_S"], "email": e["DROBU_E"],
}))' > "$WORK/claim-body.json"
    RESP="$WORK/claim-response.txt"
    HTTP_CODE=$(curl -s -o "$RESP" -w '%{http_code}' \
        --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
        -K "$WORK/curl-headers" \
        -X POST "${SUPABASE_URL}/rest/v1/license_keys" \
        -H "Content-Type: application/json" -H "Prefer: return=minimal" \
        -d @"$WORK/claim-body.json") || HTTP_CODE=000
    if [[ $HTTP_CODE != 2* ]]; then
        echo "✗ Failed to record the claim upstream (HTTP $HTTP_CODE):" >&2
        sed 's/^/    /' "$RESP" >&2 || true
        echo "  If this races a concurrent webhook vend, re-run with the same --session:" >&2
        echo "  the existing-claim check will print the winning key." >&2
        exit 1
    fi
    echo "✓ Claim recorded upstream for ${SESSION_ID} (webhook retries will return this key)"
fi

# --- Audit log ----------------------------------------------------------------
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
