#!/usr/bin/env bash
# Drobu metrics snapshot — a privacy-respecting, zero-infra readout of the
# acquisition -> revenue funnel, stitched from data you ALREADY have:
#
#   DMG downloads      GitHub release download_count   (works now, gh authed)
#   Sales + revenue    Supabase license_keys           (claimed_at/amount_total)
#   Active devices     Supabase activations            (deactivated_at IS NULL)
#   Pre-fulfillment    Stripe (optional)               (checkout sessions)
#
# It NEVER touches anything on a user's Mac — only public release stats and your
# own backend. Run it weekly; it snapshots cumulative counts to a gitignored
# history dir so it can show week-over-week deltas (GitHub's download_count is
# lifetime-cumulative and can't be windowed any other way).
#
# Setup: copy tools/.metrics-env.example to tools/.metrics-env and fill it in.
# GitHub needs nothing. See the printed hints for Supabase/Stripe.
#
# Usage: tools/metrics-snapshot.sh

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="DanieliusIsiunas/drobu"
HUMAN_ASSET="Drobu.dmg"            # website download button counts here
UPDATE_ASSET="Drobu-update.dmg"    # Sparkle auto-update counts here (must match DMG_UPDATE in release.sh)
ENV_FILE="tools/.metrics-env"
HIST_DIR="tools/.metrics-history"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# Load credentials if present (never printed). Missing file is fine — GitHub-only.
# shellcheck disable=SC1090
[[ -f $ENV_FILE ]] && set -a && source "$ENV_FILE" && set +a

command -v gh >/dev/null || { warn "gh CLI not found — install it for the downloads section."; }
command -v jq >/dev/null || { warn "jq not found (brew install jq) — required."; exit 1; }

TODAY=$(date -u +%Y-%m-%d)
mkdir -p "$HIST_DIR"

# ── DMG downloads (GitHub) ────────────────────────────────────────────────────
bold "DROBU METRICS — $TODAY"
echo
cyan "Downloads (GitHub release assets)"

RELEASES_JSON=""
if command -v gh >/dev/null; then
    RELEASES_JSON=$(gh api "repos/$REPO/releases" --paginate 2>/dev/null || echo '[]')
fi

if [[ -n $RELEASES_JSON && $RELEASES_JSON != "[]" ]]; then
    # Per-release human-download count (the un-versioned Drobu.dmg asset).
    printf '  %-10s %-12s %10s %10s\n' "release" "date" "human" "updates"
    echo "$RELEASES_JSON" | jq -r --arg h "$HUMAN_ASSET" --arg u "$UPDATE_ASSET" '
        .[] | [
            .tag_name,
            (.published_at[0:10]),
            ([.assets[] | select(.name == $h) | .download_count] | add // 0),
            ([.assets[] | select(.name == $u) | .download_count] | add // 0)
        ] | @tsv' \
    | while IFS=$'\t' read -r tag date human upd; do
        printf '  %-10s %-12s %10s %10s\n' "$tag" "$date" "$human" "$upd"
      done

    HUMAN_TOTAL=$(echo "$RELEASES_JSON" | jq --arg h "$HUMAN_ASSET" '[.[].assets[] | select(.name == $h) | .download_count] | add // 0')
    UPDATE_TOTAL=$(echo "$RELEASES_JSON" | jq --arg u "$UPDATE_ASSET" '[.[].assets[] | select(.name == $u) | .download_count] | add // 0')
    echo
    echo "  lifetime human downloads: $HUMAN_TOTAL"
    if [[ ${UPDATE_TOTAL:-0} -gt 0 ]]; then
        echo "  lifetime auto-update fetches: $UPDATE_TOTAL  (excluded from the funnel)"
    else
        dim "  note: until the release asset-name split lands, Drobu.dmg counts BOTH human"
        dim "  downloads AND Sparkle auto-update fetches — so this number is inflated."
    fi
else
    warn "  (no GitHub data — is gh authed? \`gh auth status\`)"
    HUMAN_TOTAL=0
fi

# ── Sales + revenue + active devices (Supabase) ───────────────────────────────
echo
cyan "Sales & activations (Supabase)"
SALES_COUNT="" ; REVENUE="" ; ACTIVE_DEVICES=""
if [[ -n ${SUPABASE_URL:-} && -n ${SUPABASE_KEY:-} ]]; then
    sb() { # sb <path-and-query> [extra header]   -> body on stdout, count via -D
        curl -fsS --max-time 25 --connect-timeout 8 "$SUPABASE_URL/rest/v1/$1" \
            -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $SUPABASE_KEY" "${@:2}"
    }
    # Claimed keys = paid sales. Pull the few columns we need and aggregate in jq.
    if CLAIMED=$(sb "license_keys?select=amount_total,currency,refunded_at&claimed_at=not.is.null" 2>/dev/null); then
        SALES_COUNT=$(echo "$CLAIMED" | jq 'length')
        REFUNDS=$(echo "$CLAIMED" | jq '[.[] | select(.refunded_at != null)] | length')
        # amount_total is in minor units; group by currency for an honest sum.
        REVENUE=$(echo "$CLAIMED" | jq -r '
            [.[] | select(.refunded_at == null)]
            | group_by(.currency)
            | map("\((map(.amount_total) | add) / 100 | floor) \(.[0].currency // "?" | ascii_upcase)")
            | join(", ") // "0"')
        printf '  sales (claimed keys): %s\n' "$SALES_COUNT"
        printf '  net revenue: %s   (refunds: %s)\n' "${REVENUE:-0}" "${REFUNDS:-0}"
    else
        warn "  license_keys query failed — check SUPABASE_URL / SUPABASE_KEY and that the key can read it."
    fi
    # Active devices = activation rows not deactivated. Use an exact count header.
    if ACT_HDR=$(sb "activations?select=device_hash&deactivated_at=is.null" -H "Prefer: count=exact" -H "Range: 0-0" -D - -o /dev/null 2>/dev/null); then
        ACTIVE_DEVICES=$(printf '%s' "$ACT_HDR" | sed -nE 's/^[Cc]ontent-[Rr]ange: .*\/([0-9]+).*/\1/p' | tr -d '\r')
        printf '  active devices: %s\n' "${ACTIVE_DEVICES:-?}"
    fi
else
    dim "  not configured — set SUPABASE_URL and SUPABASE_KEY in $ENV_FILE to enable."
    dim "  (license_keys gives sales + revenue + refunds; activations gives active devices)"
fi

# ── Pre-fulfillment funnel (Stripe, optional) ─────────────────────────────────
echo
cyan "Checkout funnel (Stripe, optional)"
if [[ -n ${STRIPE_KEY:-} ]]; then
    # Restricted read key. Count completed checkout sessions in the last 30 days.
    # Assignment-fallback, NOT `cmd || cmd2` inside $(...): a partial first
    # output plus a nonzero exit would concatenate (payment-infra.md trap).
    SINCE=$(date -u -v-30d +%s 2>/dev/null) || SINCE=$(date -u -d '30 days ago' +%s)
    # -H Authorization (not -u): keeps the key out of the process list (ps aux).
    if SESS=$(curl -fsS --max-time 25 --connect-timeout 8 "https://api.stripe.com/v1/checkout/sessions?limit=100&created[gte]=$SINCE" -H "Authorization: Bearer $STRIPE_KEY" 2>/dev/null); then
        TOTAL_SESS=$(echo "$SESS" | jq '.data | length')
        PAID_SESS=$(echo "$SESS" | jq '[.data[] | select(.payment_status == "paid")] | length')
        printf '  checkout sessions (30d): %s started, %s paid\n' "$TOTAL_SESS" "$PAID_SESS"
        dim "  (capped at 100; for a precise long-range count use the Supabase sales figure)"
    else
        warn "  Stripe query failed — check STRIPE_KEY (needs read on Checkout Sessions)."
    fi
else
    dim "  not configured — set STRIPE_KEY (a restricted read-only key) in $ENV_FILE to enable."
fi

# ── Conversion ────────────────────────────────────────────────────────────────
echo
cyan "Conversion"
if [[ -n ${SALES_COUNT:-} && ${HUMAN_TOTAL:-0} -gt 0 ]]; then
    RATE=$(echo "$SALES_COUNT $HUMAN_TOTAL" | awk '{ printf "%.1f", ($1/$2)*100 }')
    printf '  downloads -> paid: %s / %s = %s%%\n' "$SALES_COUNT" "$HUMAN_TOTAL" "$RATE"
    dim "  directional only: download_count is lifetime + currently update-inflated;"
    dim "  benchmark band for direct-download Mac apps is ~1.3-6.4%."
else
    dim "  needs both GitHub downloads and Supabase sales — wire Supabase to see this."
fi

# ── Week-over-week delta ──────────────────────────────────────────────────────
echo
cyan "Since last snapshot"
SNAP="$HIST_DIR/$TODAY.json"
PREV=$(ls -1 "$HIST_DIR"/*.json 2>/dev/null | grep -v "/$TODAY.json$" | tail -1 || true)
# Write the true active-devices count, or null when it could not be parsed —
# never a spurious 0 that a later delta would misread as a mass deactivation.
printf '{"date":"%s","human_downloads":%s,"sales":%s,"active_devices":%s}\n' \
    "$TODAY" "${HUMAN_TOTAL:-0}" "${SALES_COUNT:-0}" "${ACTIVE_DEVICES:-null}" > "$SNAP"
if [[ -n $PREV ]]; then
    PD=$(jq -r '.human_downloads // empty' "$PREV"); PS=$(jq -r '.sales // empty' "$PREV")
    PDATE=$(jq -r '.date // "?"' "$PREV")
    # Guard the arithmetic: a null/non-integer in an old or hand-edited snapshot
    # would otherwise abort the whole readout under set -u.
    if [[ $PD =~ ^[0-9]+$ && $PS =~ ^[0-9]+$ ]]; then
        printf '  vs %s:  downloads %+d   sales %+d\n' \
            "$PDATE" "$(( ${HUMAN_TOTAL:-0} - PD ))" "$(( ${SALES_COUNT:-0} - PS ))"
    else
        dim "  previous snapshot ($PDATE) has no comparable counts — skipping delta."
    fi
else
    dim "  first snapshot saved — run again next week to see deltas."
fi
echo
green "Snapshot saved to $SNAP"
