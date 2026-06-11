#!/usr/bin/env bash
# Export claimed license rows from the Supabase pool as CSV (stdout).
#
# Usage: ./tools/export-license-claims.sh [> claims.csv]
#
# One input of the weekly three-way reconciliation (support runbook):
#   Stripe succeeded-payments export ⋈ THIS ⋈ tools/license-log.csv
# keyed on session id / payload_hex. A succeeded Stripe payment with no row
# here is the paid-but-no-key alarm.
#
# Output contains customer emails (PII) — treat any saved copy like
# license-log.csv: local-only, gitignored locations, delete when done.

set -euo pipefail

cd "$(dirname "$0")/.."

SR_ACCOUNT="drobu-supabase-service-role"
SR_SERVICE="com.danielius.ClipboardHistory.supabase"

SUPABASE_URL="${DROBU_SUPABASE_URL:-}"
if [[ -z $SUPABASE_URL && -f supabase/.temp/project-ref ]]; then
    REF=$(cat supabase/.temp/project-ref)
    SUPABASE_URL="https://${REF}.supabase.co"
fi
if [[ -z $SUPABASE_URL ]]; then
    echo "✗ Supabase project not resolved (run 'supabase link' or set DROBU_SUPABASE_URL)." >&2
    exit 1
fi

SR_KEY=$(security find-generic-password -a "$SR_ACCOUNT" -s "$SR_SERVICE" -w 2>/dev/null) || {
    echo "✗ Supabase service-role key not in Keychain (account: $SR_ACCOUNT)." >&2
    exit 1
}

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

HTTP_CODE=$(curl -s -o "$BODY" -w '%{http_code}' \
    --max-time 60 --retry 3 --retry-delay 2 --retry-all-errors \
    "${SUPABASE_URL}/rest/v1/license_keys?claimed_at=not.is.null&select=claimed_at,email,stripe_session_id,payload_hex,key_version,amount_total,currency,email_sent_at,refunded_at&order=claimed_at.asc" \
    -H "apikey: ${SR_KEY}" \
    -H "Authorization: Bearer ${SR_KEY}") || HTTP_CODE=000

if [[ $HTTP_CODE != 200 ]]; then
    echo "✗ Export failed (HTTP $HTTP_CODE):" >&2
    sed 's/^/    /' "$BODY" >&2 || true
    exit 1
fi

python3 - "$BODY" <<'PY'
import csv, json, sys
rows = json.load(open(sys.argv[1]))
cols = ["claimed_at", "email", "stripe_session_id", "payload_hex",
        "key_version", "amount_total", "currency", "email_sent_at",
        "refunded_at"]
w = csv.writer(sys.stdout)
w.writerow(cols)
for r in rows:
    w.writerow([r.get(c) if r.get(c) is not None else "" for c in cols])
PY
