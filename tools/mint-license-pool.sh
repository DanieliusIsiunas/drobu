#!/usr/bin/env bash
# Mint a batch of pre-signed Drobu license keys and upload them to the
# Supabase pool that the stripe-webhook Edge Function vends from.
#
# Usage: ./tools/mint-license-pool.sh [N]     (default 30)
#
# Workflow:
#   1. Reads the Ed25519 private key from your login Keychain (account:
#      drobu-license-ed25519) and the Supabase service-role key (account:
#      drobu-supabase-service-role). The private key NEVER leaves this Mac —
#      the cloud only ever stores finished, pre-signed key strings.
#   2. Signs N random 32-byte payloads via swift -e CryptoKit (byte-identical
#      to the app's verifier). The key is passed to swift via the
#      environment, never interpolated into source (ps-visible) text.
#   3. Writes the batch to a durable local file (0600) BEFORE uploading.
#   4. Uploads from the batch file via PostgREST with
#      on_conflict=payload_hex ignore-duplicates — re-uploading the same
#      batch is a no-op, which is what makes crash recovery safe.
#   5. Appends rows to tools/license-log.csv (email=POOL) only after a
#      confirmed upload, then deletes the batch file.
#
# Crash recovery: if a previous run died mid-pipeline, the batch file still
# exists — this script detects it and RESUMES (re-upload + finish the CSV)
# instead of minting fresh keys. Without that, every re-run would mint new
# random payloads, never conflict, and silently double the pool.
#
# Safety rails:
#   * Refuses to run if the signing key is missing (never generates one).
#   * Batch + CSV writes happen under umask 0077 (owner-only).
#   * CSV append is idempotent per payload_hex (resume can't duplicate rows).

set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_ACCOUNT="drobu-license-ed25519"
SIGN_SERVICE="com.danielius.ClipboardHistory.license-signing"
SR_ACCOUNT="drobu-supabase-service-role"
SR_SERVICE="com.danielius.ClipboardHistory.supabase"
BATCH="tools/license-pool-batch.csv"
LOG="tools/license-log.csv"
INFO_PLIST="Sources/DrobuCore/Info.plist"

N="${1:-30}"
if ! [[ $N =~ ^[0-9]+$ ]] || (( N < 1 || N > 500 )); then
    echo "✗ N must be an integer between 1 and 500 (got: $N)" >&2
    exit 1
fi

umask 0077

# Scratch space (0700 under the umask) for curl header config, request body,
# and response capture — keeps the service-role key and the key batch off
# ps-visible command lines and out of fixed /tmp paths.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Resolve the Supabase project URL -------------------------------------
# `supabase link` records the project ref locally; fall back to an env var.
SUPABASE_URL="${DROBU_SUPABASE_URL:-}"
if [[ -z $SUPABASE_URL && -f supabase/.temp/project-ref ]]; then
    REF=$(cat supabase/.temp/project-ref)
    SUPABASE_URL="https://${REF}.supabase.co"
fi
if [[ -z $SUPABASE_URL ]]; then
    echo "✗ Supabase project not resolved." >&2
    echo "  Run 'supabase link --project-ref <ref>' once, or set DROBU_SUPABASE_URL." >&2
    exit 1
fi

# --- Credentials -----------------------------------------------------------
SR_KEY=$(security find-generic-password -a "$SR_ACCOUNT" -s "$SR_SERVICE" -w 2>/dev/null) || {
    echo "✗ Supabase service-role key not in Keychain (account: $SR_ACCOUNT)." >&2
    echo "  Store it once (Supabase dashboard → Settings → API → service_role):" >&2
    echo "    security add-generic-password -a $SR_ACCOUNT -s $SR_SERVICE -w '<key>' \\" >&2
    echo "        -j 'Supabase service-role key for the Drobu license pool' -U" >&2
    exit 1
}

KEY_VERSION=$(plutil -extract DrobuLicensePublicKey raw "$INFO_PLIST" | base64 -d | shasum -a 256 | cut -c1-8)

# --- Mint (or resume) ------------------------------------------------------
if [[ -f $BATCH ]]; then
    echo "! Unconsumed batch file found ($BATCH) — resuming its upload"
    echo "  (a previous run crashed mid-pipeline; no new keys are minted)"
else
    PRIV_B64=$(security find-generic-password -a "$SIGN_ACCOUNT" -s "$SIGN_SERVICE" -w 2>/dev/null) || {
        echo "✗ Ed25519 private key not found in Keychain (account: $SIGN_ACCOUNT)." >&2
        echo "  Run tools/generate-license-keypair.sh first. NEVER regenerate over" >&2
        echo "  an existing keypair — that invalidates every issued key." >&2
        exit 1
    }

    echo "Minting $N keys (key_version $KEY_VERSION)..."
    MINTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Key material crosses into swift via the environment only.
    OUT=$(DROBU_PRIV_B64="$PRIV_B64" DROBU_MINT_COUNT="$N" swift -e '
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
guard let privB64 = env["DROBU_PRIV_B64"],
      let privData = Data(base64Encoded: privB64) else {
    FileHandle.standardError.write("Failed to read private key from environment.\n".data(using: .utf8)!)
    exit(1)
}
guard let nStr = env["DROBU_MINT_COUNT"], let n = Int(nStr), n >= 1, n <= 500 else {
    FileHandle.standardError.write("Bad DROBU_MINT_COUNT.\n".data(using: .utf8)!)
    exit(1)
}
let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
     .replacingOccurrences(of: "+", with: "-")
     .replacingOccurrences(of: "/", with: "_")
     .replacingOccurrences(of: "=", with: "")
}

for _ in 0..<n {
    var payload = Data(count: 32)
    let result = payload.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard result == errSecSuccess else {
        FileHandle.standardError.write("Random bytes failed.\n".data(using: .utf8)!)
        exit(1)
    }
    let sig = try priv.signature(for: payload)
    print("\(b64url(payload)) \(b64url(sig)) \(payload.map { String(format: "%02x", $0) }.joined())")
}
') || { echo "✗ Signing failed." >&2; exit 1; }
    unset PRIV_B64

    LINES=$(printf '%s\n' "$OUT" | grep -c .) || LINES=0
    if [[ $LINES -ne $N ]]; then
        echo "✗ Expected $N keys, swift produced $LINES — aborting before any write." >&2
        exit 1
    fi

    # Durable batch BEFORE upload: key,payload_hex,key_version,minted_at.
    # Written to a .tmp and moved into place atomically, so a crash mid-write
    # never leaves a torn batch file that a resume would half-ingest.
    : > "$BATCH.tmp"
    while read -r PAYLOAD SIG HEX; do
        echo "DROBU-${PAYLOAD}.${SIG},${HEX},${KEY_VERSION},${MINTED_AT}" >> "$BATCH.tmp"
    done <<< "$OUT"
    mv "$BATCH.tmp" "$BATCH"
    echo "✓ Batch written ($BATCH, $N keys)"
fi

# --- Upload (idempotent on payload_hex) ------------------------------------
python3 - "$BATCH" > "$WORK/batch.json" <<'PY'
import csv, json, sys
rows = []
with open(sys.argv[1], newline="") as f:
    for key, payload_hex, key_version, minted_at in csv.reader(f):
        rows.append({"key": key, "payload_hex": payload_hex,
                     "key_version": key_version, "minted_at": minted_at})
print(json.dumps(rows))
PY

# Auth headers via a curl config file (-K): the service-role key must never
# appear on a ps-visible command line (.claude/rules/keychain-and-crypto.md).
printf 'header = "apikey: %s"\nheader = "Authorization: Bearer %s"\n' \
    "$SR_KEY" "$SR_KEY" > "$WORK/curl-headers"

UPLOAD_RESP="$WORK/upload-response.txt"
HTTP_CODE=$(curl -s -o "$UPLOAD_RESP" -w '%{http_code}' \
    --max-time 60 --retry 3 --retry-delay 2 --retry-all-errors \
    -K "$WORK/curl-headers" \
    -X POST "${SUPABASE_URL}/rest/v1/license_keys?on_conflict=payload_hex" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=ignore-duplicates,return=minimal" \
    -d @"$WORK/batch.json") || HTTP_CODE=000

if [[ $HTTP_CODE != 2* ]]; then
    echo "✗ Upload failed (HTTP $HTTP_CODE) — batch file kept for resume:" >&2
    sed 's/^/    /' "$UPLOAD_RESP" >&2 || true
    echo "  Re-run this script to resume; no CSV rows were appended." >&2
    exit 1
fi
echo "✓ Uploaded batch to ${SUPABASE_URL} (HTTP $HTTP_CODE)"

# --- Audit log (idempotent per payload_hex) --------------------------------
if [[ ! -f $LOG ]]; then
    echo "timestamp,email,payload_hex" > "$LOG"
fi
APPENDED=0
while IFS=, read -r _KEY HEX _VER TS; do
    if ! grep -qF "$HEX" "$LOG"; then
        echo "${TS},POOL,${HEX}" >> "$LOG"
        APPENDED=$((APPENDED + 1))
    fi
done < "$BATCH"
echo "✓ Audit log updated ($APPENDED new rows in $LOG)"

rm -f "$BATCH"
echo "✓ Batch file deleted (keys now live only in the pool + Keychain-guarded cloud)"
echo
echo "Done. Verify pool health: curl <function-url>/health"
