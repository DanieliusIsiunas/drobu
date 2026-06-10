#!/usr/bin/env bash
# Release verification gate for Drobu. Two modes:
#
# Usage:
#   tools/verify-release.sh --pre --app <path> --dmg <path> \
#       --version <X.Y.Z> --build <N> --ed-sig <base64> --length <bytes> \
#       [--allow-key-rotation]
#   tools/verify-release.sh --post [--version <X.Y.Z> --build <N>] \
#       [--local-dmg <path>]
#
# --pre   Pre-publish artifact gate, called by release.sh after sign_update
#         and BEFORE `git tag`. Every check here encodes a documented field
#         failure (provenance in docs/plans/2026-06-10-004 + .claude/rules/).
#         Strict: any failure blocks; nothing is published yet, re-running
#         release.sh is free. Local checks run before network checks so a
#         transient can never mask an artifact defect.
#
# --post  Synthetic Sparkle client, run AFTER publish (and standalone as a
#         health check any time). Fetches the live appcast exactly as a
#         client would, downloads the enclosure, and verifies the full
#         contract. Collect-then-report: all checks run, per-check verdicts
#         print, exit is non-zero if any failed — with state-specific
#         recovery guidance. Standalone with no flags it verifies the
#         LATEST PUBLISHED release (expected version/build derived from the
#         live appcast itself); --version requires --build (a half-defaulted
#         pair would misreport a healthy release as state C).
#
# Failure classes are distinguished, never conflated:
#   artifact verdict  -> fix the artifact / release
#   network class     -> "likely transient — re-run"
#   toolchain class   -> "swift -e could not run — check xcode-select"
#
# Test-override flags (used by tools/e2e/verify-release-selftest.sh to
# induce failures; never used by release.sh):
#   --expected-key <base64>   override the pinned SUPublicEDKey
#   --feed-url <url>          override the appcast URL probed in --pre R8
#   --skip-website-check      skip version-in-3-places (testing a foreign DMG)

set -euo pipefail

cd "$(dirname "$0")/.."

# --- Pinned contracts -----------------------------------------------------
# These constants ARE the gate. Changing any of them must be a deliberate,
# reviewed act — see docs/private/support-runbook.md before touching them.
EXPECTED_ED_KEY="XmiKqgGJ6dSmGbT3ehj6B9IUkn87vRhKbe16rTWGP54="
TEAM_ID="TGL69S88MD"
MIN_SYSTEM_VERSION="14.0"
REPO="DanieliusIsiunas/drobu"
# Canonical feed (custom domain) and the LEGACY feed baked as SUFeedURL
# into every shipped binary (it 301s to canonical). --post must confirm the
# release is live on the LEGACY URL too — that is the feed real clients
# actually fetch; if its 301 chain breaks, installed clients are stranded
# even while canonical stays green.
CANONICAL_APPCAST="https://drobu.app/appcast.xml"
LEGACY_APPCAST="https://danieliusisiunas.github.io/drobu/appcast.xml"
RAW_APPCAST="https://raw.githubusercontent.com/$REPO/main/website/public/appcast.xml"
DMG_NAME="Drobu.dmg"

# --retry-max-time bounds the WHOLE fetch (incl. retries); without it a
# degraded network can stretch each call to max-time × retries.
CURL_FLAGS=(--max-time 30 --retry-max-time 30 --retry 3 --retry-delay 2 --retry-all-errors -s)

# --- Output helpers (tools/ idiom: glyphs, not ANSI) ------------------------
pass()  { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*" >&2; }
note()  { echo "  ! $*"; }

FAILURES=0
check_fail() { fail "$*"; FAILURES=$((FAILURES + 1)); }

# Unique-per-request cache buster. Fastly caches each query-string variant
# of the Pages appcast (max-age=600) and raw.githubusercontent caches for
# ~300s — a REUSED buster value is itself cached, silently re-introducing
# staleness inside a poll loop. Never hoist this into a variable used twice.
cb() { echo "cb=$(date +%s)$RANDOM"; }

# --- Cleanup ----------------------------------------------------------------
SCRATCH=""
MOUNT_POINT=""
# Detach the current mount (retry, then -force), each step tolerant: one
# failing cleanup step must not skip the rest under set -e. Callable
# mid-run; full cleanup (which also removes SCRATCH) is EXIT-trap only —
# the selftest caught a mid-run cleanup deleting the scratch dir and
# cascading every later fetch into the network-failure class.
detach_mount() {
    if [[ -n $MOUNT_POINT ]]; then
        # Only clear MOUNT_POINT if a detach actually succeeded — otherwise
        # leave it set so the EXIT trap gets another attempt rather than
        # orphaning the volume.
        if hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
            || { sleep 2; hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; } \
            || hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1; then
            MOUNT_POINT=""
        fi
    fi
}
cleanup() {
    detach_mount
    [[ -n $SCRATCH ]] && rm -rf "$SCRATCH" || true
}
trap cleanup EXIT

# --- Shared primitives -------------------------------------------------------

# EdDSA verdict via CryptoKit. Prints EDDSA-VALID / EDDSA-INVALID and exits 0
# whenever a verdict is reached; a non-zero exit or missing sentinel is a
# TOOLCHAIN failure (xcode-select drift, pending license), not an artifact
# verdict — the two must never be conflated, or an Xcode update reads as a
# tampered release. Sparkle edSignatures are STANDARD base64 (+, /, padding);
# do not reuse the license tooling's base64url decode.
#
# SECURITY: the signature comes from a fetched appcast (--post) — untrusted
# input. It is passed to Swift via the ENVIRONMENT, never interpolated into
# the source, so a malicious appcast value cannot inject Swift/shell code
# into this release-host process. The pubkey and path are local, but go the
# same route for uniformity. A non-base64 signature is an artifact verdict
# (invalid), not a toolchain failure — gate it before spawning swift.
# Args: <file> <standard-base64-sig> <base64-pubkey>
# Output via global EDDSA_VERDICT: valid | invalid | toolchain
eddsa_verify() {
    local file="$1" sig="$2" pubkey="$3" out
    # A signature that isn't even base64 is tampered/garbled input — an
    # artifact verdict, and it also means there is nothing safe to hand to
    # Swift. (Env-passing already neutralizes injection; this keeps the
    # verdict class correct.)
    if [[ ! $sig =~ ^[A-Za-z0-9+/]+=*$ || ! $pubkey =~ ^[A-Za-z0-9+/]+=*$ ]]; then
        EDDSA_VERDICT="invalid"
        return
    fi
    out=$(VR_FILE="$file" VR_SIG="$sig" VR_PUBKEY="$pubkey" swift -e '
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let pubB64 = env["VR_PUBKEY"], let pubData = Data(base64Encoded: pubB64),
      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
      let sigB64 = env["VR_SIG"], let sig = Data(base64Encoded: sigB64),
      let path = env["VR_FILE"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    print("EDDSA-INVALID")
    exit(0)
}
print(pub.isValidSignature(sig, for: data) ? "EDDSA-VALID" : "EDDSA-INVALID")
' 2>/dev/null) || out=""
    case "$out" in
        *EDDSA-VALID*)   EDDSA_VERDICT="valid" ;;
        *EDDSA-INVALID*) EDDSA_VERDICT="invalid" ;;
        *)               EDDSA_VERDICT="toolchain" ;;
    esac
}

# Parse the newest <item> of an appcast file. Prints KEY=VALUE lines:
# APPCAST_VERSION, APPCAST_SHORT, APPCAST_MIN_OS, APPCAST_URL,
# APPCAST_LENGTH, APPCAST_SIG, APPCAST_MAX_BUILD (max sparkle:version of
# ALL items). Exits 1 on parse failure. python3 xml.etree: stock on macOS
# and ubuntu runners (xmllint is NOT on ubuntu-latest).
parse_appcast() {
    python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
try:
    tree = ET.parse(sys.argv[1])
except ET.ParseError as e:
    print(f"parse error: {e}", file=sys.stderr)
    sys.exit(1)
items = tree.findall(".//item")
if not items:
    print("no <item> elements", file=sys.stderr)
    sys.exit(1)
builds = []
for it in items:
    v = it.findtext(f"{SP}version")
    if v and v.isdigit():
        builds.append(int(v))
first = items[0]
enc = first.find("enclosure")
if enc is None:
    print("newest item has no <enclosure>", file=sys.stderr)
    sys.exit(1)
print(f"APPCAST_VERSION={first.findtext(f'{SP}version') or ''}")
print(f"APPCAST_SHORT={first.findtext(f'{SP}shortVersionString') or ''}")
print(f"APPCAST_MIN_OS={first.findtext(f'{SP}minimumSystemVersion') or ''}")
print(f"APPCAST_URL={enc.get('url') or ''}")
print(f"APPCAST_LENGTH={enc.get('length') or ''}")
print(f"APPCAST_SIG={enc.get(f'{SP}edSignature') or ''}")
print(f"APPCAST_MAX_BUILD={max(builds) if builds else 0}")
PY
}

# Fetch a URL to a file with the shared curl discipline.
# fetch <url> <outfile>  -> sets FETCH_CODE (000 on transport failure)
fetch() {
    local url="$1" out="$2"
    FETCH_CODE=$(curl "${CURL_FLAGS[@]}" -L -o "$out" -w '%{http_code}' "$url") || FETCH_CODE=000
}

# --- Argument parsing ---------------------------------------------------------
MODE=""
APP="" DMG="" VERSION="" BUILD="" ED_SIG="" LENGTH="" LOCAL_DMG=""
ALLOW_KEY_ROTATION=0
FEED_URL_OVERRIDE=""
SKIP_WEBSITE_CHECK=0
VERSION_FLAGGED=0 BUILD_FLAGGED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pre|--post) MODE="${1#--}"; shift ;;
        --app)        APP="$2"; shift 2 ;;
        --dmg)        DMG="$2"; shift 2 ;;
        --version)    VERSION="$2"; VERSION_FLAGGED=1; shift 2 ;;
        --build)      BUILD="$2"; BUILD_FLAGGED=1; shift 2 ;;
        --ed-sig)     ED_SIG="$2"; shift 2 ;;
        --length)     LENGTH="$2"; shift 2 ;;
        --local-dmg)  LOCAL_DMG="$2"; shift 2 ;;
        --expected-key) EXPECTED_ED_KEY="$2"; shift 2 ;;
        --feed-url)   FEED_URL_OVERRIDE="$2"; shift 2 ;;
        --skip-website-check) SKIP_WEBSITE_CHECK=1; shift ;;
        --allow-key-rotation) ALLOW_KEY_ROTATION=1; shift ;;
        -h|--help) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "✗ Unknown arg: $1 (see --help)" >&2; exit 2 ;;
    esac
done

[[ -n $MODE ]] || { echo "✗ Mode required: --pre or --post (see --help)" >&2; exit 2; }

# =============================================================================
# --pre: pre-publish artifact gate
# =============================================================================
run_pre() {
    [[ -n $APP && -n $DMG && -n $VERSION && -n $BUILD && -n $ED_SIG && -n $LENGTH ]] \
        || { echo "✗ --pre requires --app --dmg --version --build --ed-sig --length" >&2; exit 2; }
    [[ -d $APP ]] || { echo "✗ App bundle not found: $APP" >&2; exit 2; }
    [[ -f $DMG ]] || { echo "✗ DMG not found: $DMG" >&2; exit 2; }

    SCRATCH=$(mktemp -d -t verify-release)
    echo "Pre-publish gate: $APP + $DMG (v$VERSION, build $BUILD)"
    echo
    echo "— Local artifact checks —"

    # R1: deep/strict signature + team identity. An ad-hoc artifact shows
    # TeamIdentifier=not set; the silent ad-hoc fallback cost a v1.2 redo.
    if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
        pass "codesign --verify --deep --strict"
    else
        check_fail "codesign deep/strict verification FAILED — the bundle will not pass Gatekeeper"
    fi
    local cs_info
    cs_info=$(codesign -dvvv "$APP" 2>&1) || cs_info=""
    if grep -q "TeamIdentifier=$TEAM_ID" <<<"$cs_info"; then
        pass "TeamIdentifier=$TEAM_ID"
    else
        check_fail "TeamIdentifier is not $TEAM_ID — wrong or ad-hoc signing identity; Sparkle on installed clients will refuse this update"
    fi

    # R2: hardened runtime + secure timestamp on the app and every nested
    # Sparkle executable. flags= sits MID-LINE in the CodeDirectory line
    # (substring match only); codesign -dvvv writes to stderr. Missing
    # --timestamp is a silent local success that Apple's notary rejects.
    # Scoped to Versions/B: the framework root holds symlink duplicates.
    local nested_fail=0 checked=0 n
    while IFS= read -r n; do
        checked=$((checked + 1))
        local info
        info=$(codesign -dvvv "$n" 2>&1) || info=""
        grep -q 'flags=.*runtime' <<<"$info" || { check_fail "missing hardened runtime: $n"; nested_fail=1; }
        grep -q '^Timestamp=' <<<"$info" || { check_fail "missing secure timestamp: $n"; nested_fail=1; }
    done < <(find "$APP/Contents/Frameworks/Sparkle.framework/Versions/B" \
                  \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) 2>/dev/null; echo "$APP")
    # Guard against a vacuous pass: Sparkle 2.x ships 2 XPC services +
    # Autoupdate + Updater.app = 4 nested, plus the app = 5. If the find
    # scope ever goes stale (framework layout change), the loop would check
    # only the app and silently "pass" the nested-code contract.
    if (( checked < 5 )); then
        check_fail "R2 inspected only $checked code object(s) — the Sparkle Versions/B layout changed; update the find scope (expected 4 nested + the app)"
    elif [[ $nested_fail -eq 0 ]]; then
        pass "hardened runtime + timestamp on app + nested Sparkle code ($checked objects)"
    fi

    # R3: notarization tickets. stapler validate is the offline check of
    # exactly what Gatekeeper honors for a quarantined download.
    #
    # Do NOT add `spctl --assess --type open --context context:primary-signature`
    # on the DMG here: the DMG container is notarized + stapled but
    # intentionally NOT codesigned (only the app inside is), so spctl reports
    # "no usable signature" and false-rejects a perfectly good DMG. That
    # exact check aborted the v1.4.1 release after both notarizations had
    # already succeeded. `stapler validate` is the correct ticket check.
    # (Comment moved verbatim from release.sh — it lives with the check.)
    if xcrun stapler validate "$APP" >/dev/null 2>&1; then
        pass "stapler validate (app)"
    else
        check_fail "app has no valid notarization ticket — was it stapled?"
    fi
    if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
        pass "stapler validate (DMG)"
    else
        check_fail "DMG has no valid notarization ticket — staple before signing"
    fi

    # R6: the appcast length must equal the FINAL DMG bytes. Stapling
    # rewrites the DMG, so a mismatch here means sign_update ran before
    # stapling — every client download would fail EdDSA validation.
    local dmg_size
    dmg_size=$(stat -f%z "$DMG") || dmg_size=0
    if [[ $dmg_size == "$LENGTH" ]]; then
        pass "length $LENGTH == DMG byte size"
    else
        check_fail "length mismatch: appcast will say $LENGTH but DMG is $dmg_size bytes — was the DMG re-stapled after sign_update?"
    fi

    # R5: pinned EdDSA key + signature verification over the final bytes.
    local built_key
    built_key=$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" 2>/dev/null) || built_key=""
    if [[ $built_key == "$EXPECTED_ED_KEY" ]]; then
        pass "SUPublicEDKey matches the pinned key"
    else
        check_fail "SUPublicEDKey in the built bundle ($built_key) != pinned key — EdDSA rotation strands every installed client (see runbook)"
    fi
    eddsa_verify "$DMG" "$ED_SIG" "$EXPECTED_ED_KEY"
    case "$EDDSA_VERDICT" in
        valid)     pass "EdDSA signature verifies against the pinned key" ;;
        invalid)   check_fail "EdDSA signature does NOT verify against the pinned key — clients cannot install this update" ;;
        toolchain) check_fail "swift -e could not run — toolchain issue (check xcode-select / Xcode license), NOT an artifact verdict" ;;
    esac

    # R7a: the built bundle is the version we think we're shipping.
    local bundle_version bundle_build
    bundle_version=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null) || bundle_version=""
    bundle_build=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist" 2>/dev/null) || bundle_build=""
    if [[ $bundle_version == "$VERSION" && $bundle_build == "$BUILD" ]]; then
        pass "built bundle is v$VERSION (build $BUILD)"
    else
        check_fail "built bundle says v$bundle_version (build $bundle_build), expected v$VERSION ($BUILD) — stale build?"
    fi

    # R7b: version-in-3-places (delimiter-anchored: a bare v1.5 would
    # prefix-match v1.5.2).
    if [[ $SKIP_WEBSITE_CHECK -eq 0 ]]; then
        if grep -qF "Version $VERSION<" website/src/components/DownloadCTA.astro; then
            pass "DownloadCTA.astro shows Version $VERSION"
        else
            check_fail "website/src/components/DownloadCTA.astro does not contain 'Version $VERSION<' — update the version in 3 places (CLAUDE.md) [or the markup moved: update this check]"
        fi
        if grep -qF ">v$VERSION<" website/src/components/Footer.astro; then
            pass "Footer.astro shows v$VERSION"
        else
            check_fail "website/src/components/Footer.astro does not contain '>v$VERSION<' — update the version in 3 places (CLAUDE.md) [or the markup moved: update this check]"
        fi
    fi

    # R4: inspect the artifact users actually mount. Mount point parsed from
    # -plist output (never /Volumes/Drobu by name — a stale volume from an
    # earlier run would silently make us inspect the wrong artifact).
    local attach_plist
    if attach_plist=$(hdiutil attach -plist -nobrowse -readonly "$DMG" 2>/dev/null); then
        MOUNT_POINT=$(python3 -c "
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
for e in d.get('system-entities', []):
    mp = e.get('mount-point')
    if mp:
        print(mp)
        break
" <<<"$attach_plist") || MOUNT_POINT=""
        if [[ -n $MOUNT_POINT && -d "$MOUNT_POINT/Drobu.app" ]]; then
            local in_dmg_app="$MOUNT_POINT/Drobu.app"
            if [[ -L "$in_dmg_app/Contents/Frameworks/Sparkle.framework/Versions/Current" ]]; then
                pass "Sparkle Versions/Current is a symlink inside the DMG (ditto, not cp -r)"
            else
                check_fail "Sparkle Versions/Current is NOT a symlink in the DMG — cp -r corruption breaks code signing on clients"
            fi
            if codesign --verify --deep --strict "$in_dmg_app" >/dev/null 2>&1; then
                pass "in-DMG app passes deep/strict verification"
            else
                check_fail "in-DMG app FAILS deep/strict verification"
            fi
            if xcrun stapler validate "$in_dmg_app" >/dev/null 2>&1; then
                pass "in-DMG app carries its own staple ticket (app stapled before packaging)"
            else
                check_fail "in-DMG app has NO staple ticket — Sparkle-extracted installs will be un-ticketed; staple the app BEFORE create-dmg"
            fi
        else
            check_fail "mounted DMG but found no Drobu.app at mount point '$MOUNT_POINT'"
        fi
        detach_mount  # trap remains as backstop
    else
        note "hdiutil attach failed — retryable environment issue, not an artifact verdict; re-run"
        FAILURES=$((FAILURES + 1))
    fi

    echo
    echo "— Network checks (any failure here blocks; if it smells transient, just re-run) —"

    # R8: the feed URL baked into THIS build must serve a live appcast.
    # -L is required: shipped github.io URLs 301 to drobu.app since the
    # custom-domain attach; a no-redirect probe would false-fail a healthy
    # feed. Body shape asserted, never status alone.
    local feed
    feed=${FEED_URL_OVERRIDE:-$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist" 2>/dev/null)} || feed=""
    local feed_body="$SCRATCH/feed.xml"
    if [[ -z $feed ]]; then
        # Deterministic artifact defect (key removed/renamed in Info.plist —
        # the v1.2-class feed-contract regression). NOT network: re-running
        # rebuilds from the same plist and re-fails. Don't even attempt the
        # fetch (an empty URL degenerates to "?cb=…" and curl burns retries).
        check_fail "the built bundle has no readable SUFeedURL — installed clients would have no update feed at all (artifact defect, not network)"
    elif fetch "${feed}?$(cb)" "$feed_body"; [[ $FETCH_CODE == 200 ]] && grep -q '<enclosure url=' "$feed_body" && grep -q 'sparkle:version' "$feed_body"; then
        pass "SUFeedURL serves a live appcast ($feed)"
    elif [[ $FETCH_CODE == 000 ]]; then
        check_fail "network failure fetching SUFeedURL ($feed) — likely transient, re-run; if persistent, clients can't update either"
    else
        check_fail "SUFeedURL ($feed) returned $FETCH_CODE or non-appcast content — installed clients would silently see 'no updates' (the v1.2 stranding class)"
    fi

    # R9: build number strictly greater than everything already published,
    # else no installed client is ever OFFERED this update — silently.
    # Repo-local appcast is a fallback for OBTAINING the max only; failing
    # to obtain any max is a network-class block, never a pass.
    local max_build=""
    if appcast_vals=$(parse_appcast "$feed_body" 2>/dev/null); then
        max_build=$(sed -n 's/^APPCAST_MAX_BUILD=//p' <<<"$appcast_vals")
    elif appcast_vals=$(parse_appcast "website/public/appcast.xml" 2>/dev/null); then
        max_build=$(sed -n 's/^APPCAST_MAX_BUILD=//p' <<<"$appcast_vals")
        note "using repo-local appcast for max build (live fetch unusable)"
    fi
    if [[ -z $max_build ]]; then
        check_fail "could not determine the published max build number from live or local appcast — network-class failure, re-run"
    elif (( BUILD > max_build )); then
        pass "build $BUILD > published max $max_build"
    else
        check_fail "CFBundleVersion $BUILD is not greater than the published max $max_build — Sparkle will never offer this update; bump CFBundleVersion"
    fi

    # R5b: key continuity against the PREVIOUSLY SHIPPED artifact. The local
    # pins catch accidental rotation; a deliberate joint key+cert rotation
    # edits the pins in the same commit — but it cannot edit the bundle
    # installed clients already hold. Verify the new signature against the
    # key inside the live latest release's app.
    if [[ $ALLOW_KEY_ROTATION -eq 1 ]]; then
        note "KEY ROTATION ALLOWED by explicit flag — installed clients can only follow if SUPublicEDKey is unchanged in the bundle they hold. See runbook 'key rotation' before shipping this."
    else
        local prev_url prev_dmg="$SCRATCH/prev.dmg"
        prev_url=$(sed -n 's/^APPCAST_URL=//p' <<<"${appcast_vals:-}")
        if [[ -n $prev_url ]]; then
            fetch "$prev_url" "$prev_dmg"
            if [[ $FETCH_CODE == 200 ]]; then
                local prev_plist prev_key=""
                if prev_plist=$(hdiutil attach -plist -nobrowse -readonly "$prev_dmg" 2>/dev/null); then
                    MOUNT_POINT=$(python3 -c "
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
for e in d.get('system-entities', []):
    mp = e.get('mount-point')
    if mp:
        print(mp)
        break
" <<<"$prev_plist") || MOUNT_POINT=""
                    [[ -n $MOUNT_POINT ]] && prev_key=$(plutil -extract SUPublicEDKey raw "$MOUNT_POINT/Drobu.app/Contents/Info.plist" 2>/dev/null) || prev_key=""
                    detach_mount
                fi
                if [[ -z $prev_key ]]; then
                    # Can't read the previously-shipped key → can't PROVE
                    # continuity. Fail closed (like R8/R9's network class):
                    # this check is the sole guard against a joint key+cert
                    # rotation stranding every installed client, so an
                    # un-checkable run must block, not pass. Re-running is free.
                    check_fail "could not read SUPublicEDKey from the previous release's bundle — key continuity is UNVERIFIED; re-run (or pass --allow-key-rotation if you are intentionally rotating, runbook first)"
                else
                    eddsa_verify "$DMG" "$ED_SIG" "$prev_key"
                    case "$EDDSA_VERDICT" in
                        valid)     pass "key continuity: new signature verifies against the PREVIOUSLY SHIPPED key" ;;
                        invalid)   check_fail "key continuity BROKEN: installed clients (holding the previous release's SUPublicEDKey) cannot verify this update. If rotation is truly intended, re-run with --allow-key-rotation (runbook first)" ;;
                        toolchain) check_fail "swift -e could not run during key-continuity check — toolchain issue, not a verdict" ;;
                    esac
                fi
            else
                # Download failure → continuity UNVERIFIED. Fail closed: a
                # transient outage must not be a window through which a
                # client-stranding key rotation can ship. Blocking is cheap
                # (nothing published; re-run), consistent with every other
                # --pre network check.
                check_fail "could not download the previous release ($prev_url) to verify key continuity — UNVERIFIED; re-run when reachable (or pass --allow-key-rotation if intentionally rotating, runbook first)"
            fi
        else
            # No previous enclosure = genuine first release: there are no
            # installed clients holding a prior key, so there is nothing to
            # strand. This is the ONE legitimate skip (not a failure).
            note "no previous enclosure in the appcast — first release, key-continuity check not applicable"
        fi
    fi

    echo
    if [[ $FAILURES -gt 0 ]]; then
        echo "✗ PRE-PUBLISH GATE FAILED ($FAILURES check(s)). Nothing was published." >&2
        echo "  Fix and re-run release.sh — re-running is free at this stage. The local $DMG_NAME is kept for inspection." >&2
        exit 1
    fi
    echo "✓ Pre-publish gate passed — clear to tag and publish."
}

# =============================================================================
# --post: synthetic Sparkle client
# =============================================================================
run_post() {
    SCRATCH=$(mktemp -d -t verify-release)

    # Expected-version semantics (R14): explicit flags are for "verify the
    # release I just published"; standalone means "verify the latest
    # published release" (derived from the live appcast itself). A
    # half-defaulted pair would land a healthy release in the state-C alarm.
    if [[ $VERSION_FLAGGED -ne $BUILD_FLAGGED ]]; then
        echo "✗ --version and --build must be passed together (a half-defaulted pair misreports release state)" >&2
        exit 2
    fi

    echo "Post-publish verification (synthetic Sparkle client)"
    echo

    # Poll the live appcast. Cache-busted per request: Pages sits behind
    # Fastly (max-age=600) and raw.githubusercontent caches ~300s; each
    # query-string variant is itself cached, so the buster must be unique
    # every iteration. Propagation budget 12 min (GitHub documents Pages
    # publication up to 10 min) — content failures never wait.
    # Deadline-based, not attempt-counted: a degraded network must not
    # stretch the wall-clock budget. 720s = GitHub's documented 10-min Pages
    # publication bound + slack.
    local deadline=$((SECONDS + 720)) interval=15
    local live_body="$SCRATCH/live.xml" appcast_vals=""
    local expected_version="$VERSION" expected_build="$BUILD"
    local state="polling"
    # State C ("appcast never pushed") is the most alarming verdict, so it
    # demands a CONFIRMED-absent reading, never a failed fetch: require N
    # consecutive raw probes that returned 200 yet lacked the version. A
    # transient (000/5xx) or replication lag right after the push must NOT
    # conclude C — it routes back through the propagation budget.
    local raw_confirmed_misses=0 raw_miss_threshold=3

    while (( SECONDS < deadline )); do
        fetch "${CANONICAL_APPCAST}?$(cb)" "$live_body"
        if [[ $FETCH_CODE == 000 ]]; then
            note "network failure fetching live appcast — retrying"
            sleep "$interval"; continue
        fi
        if [[ $FETCH_CODE != 200 ]]; then
            check_fail "live appcast returned $FETCH_CODE — installed clients silently see 'no updates'"
            state="dead"; break
        fi
        if ! appcast_vals=$(parse_appcast "$live_body" 2>"$SCRATCH/parse-err"); then
            check_fail "live appcast does not parse as XML ($(cat "$SCRATCH/parse-err")) — to Sparkle clients a broken appcast is indistinguishable from 'no updates'. Fix website/public/appcast.xml and push."
            state="garbage"; break
        fi
        local live_version live_build
        live_version=$(sed -n 's/^APPCAST_SHORT=//p' <<<"$appcast_vals")
        live_build=$(sed -n 's/^APPCAST_VERSION=//p' <<<"$appcast_vals")

        # Standalone derive-from-live: the latest published item IS the
        # expectation; cross-check its tag exists. ls-remote's exit status
        # and output are captured separately — a non-zero exit is a
        # network/auth class (re-run), never an artifact disagreement.
        if [[ -z $expected_version ]]; then
            expected_version="$live_version"; expected_build="$live_build"
            local ls_out ls_rc=0
            ls_out=$(git ls-remote --tags origin "v$expected_version" 2>/dev/null) || ls_rc=$?
            if [[ $ls_rc -ne 0 ]]; then
                check_fail "could not reach the git remote to confirm the v$expected_version tag — network/credentials class, not a release verdict; re-run"
                state="dead"; break
            elif [[ -n $ls_out ]]; then
                note "standalone mode: verifying latest published release v$expected_version (build $expected_build)"
            else
                check_fail "live appcast's latest item is v$expected_version but no v$expected_version tag exists on the remote — appcast and releases disagree"
                state="garbage"; break
            fi
        fi

        if [[ $live_version == "$expected_version" && $live_build == "$expected_build" ]]; then
            state="live"; break
        fi

        # Stale: is it propagation (raw main already has it) or was the
        # appcast never pushed (state C)? The raw probe gets the SAME
        # transient tolerance as the canonical fetch — a non-200 is retried,
        # never read as "never pushed".
        local raw_body="$SCRATCH/raw.xml"
        fetch "${RAW_APPCAST}?$(cb)" "$raw_body"
        if [[ $FETCH_CODE != 200 ]]; then
            note "raw appcast probe returned $FETCH_CODE — transient, retrying (not concluding 'never pushed' on a failed fetch)"
            sleep "$interval"; continue
        fi
        if grep -qF "<sparkle:shortVersionString>$expected_version<" "$raw_body"; then
            raw_confirmed_misses=0
            note "appcast on main has v$expected_version; Pages still serving v$live_version — propagation"
            sleep "$interval"
        else
            raw_confirmed_misses=$((raw_confirmed_misses + 1))
            if (( raw_confirmed_misses >= raw_miss_threshold )); then
                check_fail "RELEASE v$expected_version IS LIVE BUT THE APPCAST WAS NEVER UPDATED — main lacks the item across $raw_miss_threshold confirmed reads; no client will ever see this update."
                echo "  Recover: insert the v$expected_version <item> into website/public/appcast.xml and push to main." >&2
                echo "  Do NOT delete the tag or release. (release.sh prints the exact item XML; or re-run its appcast step.)" >&2
                state="stateC"; break
            fi
            note "main does not yet show v$expected_version ($raw_confirmed_misses/$raw_miss_threshold confirmed misses) — could be replication lag, retrying"
            sleep "$interval"
        fi
    done

    if [[ $state == "polling" ]]; then
        # Budget exhausted in the propagation state — disambiguate via the
        # deploy run before alarming. Read BOTH status and conclusion: a
        # FAILED deploy reads status=completed, which alone is
        # indistinguishable from a slow-but-successful CDN. An unauthenticated
        # gh collapses to "unknown" — reported as such, not as a verdict.
        local run_info
        run_info=$(gh run list --workflow=deploy-website.yml --repo "$REPO" --limit 1 --json status,conclusion --jq '.[0] | "\(.status)/\(.conclusion)"' 2>/dev/null) || run_info="unknown"
        case "$run_info" in
            in_progress/*|queued/*)
                echo "! VERIFICATION INCOMPLETE — the Pages deploy is still running ($run_info) after the budget." >&2
                echo "  Re-run when it finishes: tools/verify-release.sh --post --version $expected_version --build $expected_build --local-dmg $LOCAL_DMG" >&2
                exit 1 ;;
            completed/success)
                check_fail "appcast still serving the previous version after the budget though the deploy SUCCEEDED — CDN cache or a deploy that didn't include the appcast commit; check the deploy run's files" ;;
            completed/failure|completed/cancelled)
                check_fail "the Pages deploy ($run_info) did not succeed — the appcast never went live; re-run the deploy-website workflow" ;;
            *)
                check_fail "appcast still serving a previous version and the deploy run state is '$run_info' (gh unauthenticated?) — check: gh run list --workflow=deploy-website.yml" ;;
        esac
    fi

    if [[ $state == "live" ]]; then
        pass "live appcast's latest item is v$expected_version (build $expected_build)"

        # The feed REAL clients fetch is the baked SUFeedURL (legacy
        # github.io), which 301s to canonical. Confirm the release is live
        # THERE too, followed exactly as Sparkle would — if the 301 chain is
        # broken or the legacy feed is stale, every installed client is
        # stranded even though canonical (checked above) is current.
        local legacy_body="$SCRATCH/legacy.xml" legacy_vals legacy_short legacy_build
        fetch "${LEGACY_APPCAST}?$(cb)" "$legacy_body"
        if [[ $FETCH_CODE != 200 ]]; then
            check_fail "the baked SUFeedURL ($LEGACY_APPCAST) returned $FETCH_CODE following redirects — installed clients fetch THIS url and would silently see 'no updates' (the 301 chain to drobu.app may be broken)"
        elif ! legacy_vals=$(parse_appcast "$legacy_body" 2>/dev/null); then
            check_fail "the baked SUFeedURL serves unparseable XML — installed clients see 'no updates'"
        else
            legacy_short=$(sed -n 's/^APPCAST_SHORT=//p' <<<"$legacy_vals")
            legacy_build=$(sed -n 's/^APPCAST_VERSION=//p' <<<"$legacy_vals")
            if [[ $legacy_short == "$expected_version" && $legacy_build == "$expected_build" ]]; then
                pass "baked SUFeedURL (legacy github.io) also serves v$expected_version — installed clients see the release"
            else
                check_fail "baked SUFeedURL serves v$legacy_short (build $legacy_build), not v$expected_version — installed clients are stranded on a stale feed while canonical is current"
            fi
        fi

        # Content checks on what a real client consumes.
        local min_os enc_url enc_length enc_sig
        min_os=$(sed -n 's/^APPCAST_MIN_OS=//p' <<<"$appcast_vals")
        enc_url=$(sed -n 's/^APPCAST_URL=//p' <<<"$appcast_vals")
        enc_length=$(sed -n 's/^APPCAST_LENGTH=//p' <<<"$appcast_vals")
        enc_sig=$(sed -n 's/^APPCAST_SIG=//p' <<<"$appcast_vals")

        if [[ $min_os == "$MIN_SYSTEM_VERSION" ]]; then
            pass "minimumSystemVersion is $MIN_SYSTEM_VERSION"
        else
            check_fail "minimumSystemVersion is '$min_os', expected $MIN_SYSTEM_VERSION — the regex appcast insertion may have garbled the item; fix in place and push"
        fi

        local dl="$SCRATCH/downloaded.dmg"
        fetch "$enc_url" "$dl"
        if [[ $FETCH_CODE == 200 ]]; then
            pass "enclosure downloads ($enc_url)"
            local dl_size
            dl_size=$(stat -f%z "$dl") || dl_size=0
            if [[ $dl_size == "$enc_length" ]]; then
                pass "downloaded bytes ($dl_size) == enclosure length"
            else
                check_fail "downloaded $dl_size bytes but enclosure says $enc_length — Sparkle clients will reject the download; fix the appcast length in place and push"
            fi
            eddsa_verify "$dl" "$enc_sig" "$EXPECTED_ED_KEY"
            case "$EDDSA_VERDICT" in
                valid)     pass "EdDSA signature verifies (the exact check every client runs)" ;;
                invalid)   check_fail "EdDSA signature INVALID over the published bytes — clients CANNOT install this update. If the DMG is good, re-sign and fix the appcast signature in place; if the DMG is bad, delete release+tag and revert the appcast commit" ;;
                toolchain) check_fail "swift -e could not run — toolchain issue, not a verdict; re-run after checking xcode-select" ;;
            esac
            if xcrun stapler validate "$dl" >/dev/null 2>&1; then
                pass "downloaded DMG carries a valid notarization ticket"
            else
                check_fail "downloaded DMG has NO valid staple ticket — Gatekeeper will warn every direct-download user"
            fi
            if [[ -n $LOCAL_DMG && -f $LOCAL_DMG ]]; then
                local sha_local sha_remote
                sha_local=$(shasum -a 256 "$LOCAL_DMG" | cut -d' ' -f1)
                sha_remote=$(shasum -a 256 "$dl" | cut -d' ' -f1)
                if [[ $sha_local == "$sha_remote" ]]; then
                    pass "published asset is byte-identical to the local DMG"
                else
                    check_fail "published asset SHA256 differs from the local DMG — the wrong file was uploaded; delete the release asset and re-upload"
                fi
            fi
        elif [[ $FETCH_CODE == 000 ]]; then
            check_fail "network failure downloading the enclosure — likely transient, re-run --post"
        else
            check_fail "enclosure URL returned $FETCH_CODE ($enc_url) — release asset missing or renamed; every update fails"
        fi

        # R12: the stable latest/download alias must point at this release.
        # The version is visible ONLY in the first-hop %{redirect_url}
        # (with -L, %{url_effective} ends at release-assets.githubusercontent
        # and never contains the version — verified live).
        local hop expected_hop="https://github.com/$REPO/releases/download/v$expected_version/$DMG_NAME"
        hop=$(curl -s --max-time 15 -o /dev/null -w '%{redirect_url}' "https://github.com/$REPO/releases/latest/download/$DMG_NAME") || hop=""
        if [[ $hop == "$expected_hop" ]]; then
            pass "releases/latest/download/$DMG_NAME points at v$expected_version"
        elif [[ -z $hop ]]; then
            check_fail "latest/download alias returned no redirect — network or GitHub issue; re-run"
        else
            check_fail "latest/download alias points at '$hop', expected v$expected_version — the website Download button serves the wrong release (newer release exists, or asset misnamed)"
        fi

        local dl_code
        dl_code=$(curl "${CURL_FLAGS[@]}" -L -o /dev/null -w '%{http_code}' "https://github.com/$REPO/releases/latest/download/$DMG_NAME") || dl_code=000
        if [[ $dl_code == 200 ]]; then
            pass "latest/download alias downloads (200)"
        else
            check_fail "latest/download alias GET returned $dl_code — the website Download button is broken"
        fi
    fi

    echo
    if [[ $FAILURES -gt 0 ]]; then
        echo "✗ POST-PUBLISH VERIFICATION FAILED ($FAILURES check(s))." >&2
        echo "  Release v${expected_version:-?} is PUBLIC and UNVERIFIED — treat the messages above as the runbook." >&2
        exit 1
    fi
    echo "✓ Post-publish verification passed — clients can see, download, and verify v$expected_version."
}

case "$MODE" in
    pre)  run_pre ;;
    post) run_post ;;
esac
