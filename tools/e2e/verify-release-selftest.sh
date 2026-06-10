#!/usr/bin/env bash
# Self-test for tools/verify-release.sh: proves every check can FAIL
# correctly and PASS correctly against live published artifacts.
#
# Usage: tools/e2e/verify-release-selftest.sh
#
# A verification gate whose failure paths have never been seen to fire is
# the silent-ad-hoc-fallback trap in new clothes — run this after ANY edit
# to verify-release.sh.
#
# SELF-CALIBRATING: fixtures (version/build/url/sig/length) are derived
# from the live appcast's LATEST item at runtime, so this survives every
# future release unchanged. The only hardcoded fixture is the dead
# pre-rename appcast URL (the actual v1.2 stranding incident), which
# assumes no forwarding stub is ever stood up at the old repo name.
#
# Network-dependent developer tool — NOT part of swift-test CI.

set -euo pipefail

cd "$(dirname "$0")/../.."

VERIFY="tools/verify-release.sh"
APPCAST_URL="https://drobu.app/appcast.xml"
DEAD_FEED="https://danieliusisiunas.github.io/clipboard-history/appcast.xml"

SCRATCH=$(mktemp -d -t verify-selftest)
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0

# expect_fail <name> <expected-message-grep> <exit-code...>: run the command
# captured in CMD[] and require non-zero exit AND the distinguishing message.
# A check that fails with the WRONG message is a bug.
run_case() {
    local name="$1" want="$2"; shift 2
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]] && grep -qF "$want" <<<"$out"; then
        echo "✓ $name"
        PASS=$((PASS + 1))
    else
        echo "✗ $name (exit=$rc; wanted message containing: $want)"
        printf '%s\n' "$out" | sed 's/^/    /' | tail -15
        FAIL=$((FAIL + 1))
    fi
}

run_pass_case() {
    local name="$1"; shift
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "✓ $name"
        PASS=$((PASS + 1))
    else
        echo "✗ $name (expected success, exit=$rc)"
        printf '%s\n' "$out" | sed 's/^/    /' | tail -20
        FAIL=$((FAIL + 1))
    fi
}

echo "— Calibrating from the live appcast —"
CAL=$(python3 - <<PY
import urllib.request, xml.etree.ElementTree as ET, time, random
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
url = "$APPCAST_URL?cb=%d%d" % (time.time(), random.randint(0, 99999))
req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
tree = ET.parse(urllib.request.urlopen(req, timeout=30))
item = tree.findall(".//item")[0]
enc = item.find("enclosure")
print(item.findtext(f"{SP}shortVersionString"))
print(item.findtext(f"{SP}version"))
print(enc.get("url"))
print(enc.get("length"))
print(enc.get(f"{SP}edSignature"))
PY
)
LIVE_VERSION=$(sed -n 1p <<<"$CAL")
LIVE_BUILD=$(sed -n 2p <<<"$CAL")
LIVE_URL=$(sed -n 3p <<<"$CAL")
LIVE_LENGTH=$(sed -n 4p <<<"$CAL")
LIVE_SIG=$(sed -n 5p <<<"$CAL")
echo "  latest published: v$LIVE_VERSION (build $LIVE_BUILD), $LIVE_LENGTH bytes"

echo "— Downloading the live DMG (positive fixture) —"
DMG="$SCRATCH/live.dmg"
curl -sL --max-time 60 --retry 3 -o "$DMG" "$LIVE_URL"
[[ $(stat -f%z "$DMG") == "$LIVE_LENGTH" ]] || { echo "✗ calibration download size mismatch"; exit 1; }

TAMPERED="$SCRATCH/tampered.dmg"
cp "$DMG" "$TAMPERED"
dd if=/dev/zero of="$TAMPERED" bs=1 count=1 seek=2000000 conv=notrunc 2>/dev/null
cmp -s "$DMG" "$TAMPERED" && { echo "✗ tampering no-op"; exit 1; }

echo
echo "— Positive paths (live artifacts) —"

run_pass_case "standalone --post verifies the latest published release" \
    "$VERIFY" --post

# stapler on pristine: direct (the verifier wraps it; prove the primitive too)
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "✓ pristine live DMG passes stapler validate"; PASS=$((PASS + 1))
else
    echo "✗ pristine live DMG FAILED stapler validate"; FAIL=$((FAIL + 1))
fi

echo
echo "— Induced failures (each must fire with its distinguishing message) —"

# stapler tamper: asserts EXIT CODE only — verified empirically that the
# failure emits no error text (just the "Processing:" line), exit 65.
rc=0
xcrun stapler validate "$TAMPERED" >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
    echo "✓ tampered DMG fails stapler validate (exit $rc)"; PASS=$((PASS + 1))
else
    echo "✗ tampered DMG PASSED stapler validate"; FAIL=$((FAIL + 1))
fi

# EdDSA: tampered bytes against the real published signature.
run_case "tampered DMG fails EdDSA against the published signature" \
    "EdDSA signature does NOT verify" \
    "$VERIFY" --pre --app /Applications/Drobu.app --dmg "$TAMPERED" \
        --version "$LIVE_VERSION" --build "$LIVE_BUILD" \
        --ed-sig "$LIVE_SIG" --length "$LIVE_LENGTH" --skip-website-check

# Wrong pinned key against the pristine DMG (overridden via test flag).
run_case "pristine DMG fails against a wrong pinned key" \
    "SUPublicEDKey in the built bundle" \
    "$VERIFY" --pre --app /Applications/Drobu.app --dmg "$DMG" \
        --version "$LIVE_VERSION" --build "$LIVE_BUILD" \
        --ed-sig "$LIVE_SIG" --length "$LIVE_LENGTH" --skip-website-check \
        --expected-key "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# Length off-by-one.
run_case "length off-by-one fails" \
    "length mismatch" \
    "$VERIFY" --pre --app /Applications/Drobu.app --dmg "$DMG" \
        --version "$LIVE_VERSION" --build "$LIVE_BUILD" \
        --ed-sig "$LIVE_SIG" --length "$((LIVE_LENGTH + 1))" --skip-website-check

# Strictly-greater build: == live max must fail (free negative test).
run_case "build == published max fails the strictly-greater check" \
    "is not greater than the published max" \
    "$VERIFY" --pre --app /Applications/Drobu.app --dmg "$DMG" \
        --version "$LIVE_VERSION" --build "$LIVE_BUILD" \
        --ed-sig "$LIVE_SIG" --length "$LIVE_LENGTH" --skip-website-check

# Version-in-3-places: a version the website does not show.
run_case "bogus version fails the website consistency check" \
    "does not contain" \
    "$VERIFY" --pre --app /Applications/Drobu.app --dmg "$DMG" \
        --version "9.9.9" --build "9999" \
        --ed-sig "$LIVE_SIG" --length "$LIVE_LENGTH"

# Feed liveness: the actual v1.2 stranding URL as permanent fixture.
run_case "dead pre-rename feed URL fails liveness" \
    "the v1.2 stranding class" \
    "$VERIFY" --pre --app /Applications/Drobu.app --dmg "$DMG" \
        --version "$LIVE_VERSION" --build "$LIVE_BUILD" \
        --ed-sig "$LIVE_SIG" --length "$LIVE_LENGTH" --skip-website-check \
        --feed-url "$DEAD_FEED"

# State C: expect a version newer than anything published.
NEXT_BUILD=$((LIVE_BUILD + 1))
run_case "--post for an unpublished version reports the never-pushed state" \
    "APPCAST WAS NEVER UPDATED" \
    "$VERIFY" --post --version "99.0.$NEXT_BUILD" --build "$NEXT_BUILD"

# R14 paired-flags guard.
run_case "--version without --build is a usage error" \
    "must be passed together" \
    "$VERIFY" --post --version "$LIVE_VERSION"

# Missing mode.
run_case "missing mode is a usage error" \
    "Mode required" \
    "$VERIFY"

echo
echo "— Scoreboard —"
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "✗ SELF-TEST FAILED — do not trust the gate until this is green." >&2
    exit 1
fi
echo "✓ All checks proven to fire correctly."
