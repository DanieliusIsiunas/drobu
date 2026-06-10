#!/usr/bin/env bash
# Cuts a Drobu release end-to-end:
#   1. Reads version from Info.plist
#   2. Builds and code-signs the app
#   3. Packages Drobu.app into a Drobu.dmg with create-dmg
#      (drag-to-Applications window layout, "Drobu" volume name)
#   4. Signs the DMG with Sparkle (reads private key from Keychain)
#   5. Tags the commit and pushes
#   6. Creates a GitHub Release with the DMG attached
#   7. Updates website/public/appcast.xml with the new <item>
#   8. Commits + pushes the appcast (GH Pages picks it up automatically)
#
# Bump the version in Info.plist (CFBundleShortVersionString + CFBundleVersion)
# and commit that on main before running this script.
#
# Reversible if any step fails: tag/release/appcast commits can be deleted
# manually; the local DMG is removed at the end either way.

set -euo pipefail

cd "$(dirname "$0")"

REPO="DanieliusIsiunas/drobu"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
PLIST="Sources/DrobuCore/Info.plist"
APPCAST="website/public/appcast.xml"
TEAM_ID="TGL69S88MD"
# notarytool keychain profile — created once via:
#   xcrun notarytool store-credentials "notary-profile" \
#       --apple-id <apple-id> --team-id TGL69S88MD --password <app-specific-password>
NOTARY_PROFILE="notary-profile"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
step()   { printf '\033[36m→ %s\033[0m\n' "$*"; }

# Submit a zip/dmg to Apple's notary service and block until a verdict.
# notarytool --wait exits non-zero on "Invalid"; under `set -e` that aborts the
# release. On rejection, pull the log so the failing requirement is visible.
notarize() {
    local archive="$1"
    local submit_out
    if ! submit_out=$(xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1); then
        red "Notarization FAILED for $archive:"
        echo "$submit_out"
        local sub_id
        sub_id=$(printf '%s\n' "$submit_out" | sed -nE 's/.*id: ([0-9a-f-]+).*/\1/p' | head -1)
        [[ -n $sub_id ]] && xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE"
        return 1
    fi
    # Print a short summary, but don't let grep's exit code (1 when neither token
    # is present) become the function's — a successful submit must return 0.
    printf '%s\n' "$submit_out" | grep -E 'status:|id:' | head -3 || true
    return 0
}

# --- Pre-flight ---------------------------------------------------------------

[[ -x $SIGN_UPDATE ]] || { red "sign_update not at $SIGN_UPDATE — run ./build.sh once to fetch Sparkle artifacts."; exit 1; }
command -v gh         >/dev/null || { red "gh CLI not installed."; exit 1; }
command -v plutil     >/dev/null || { red "plutil not on PATH."; exit 1; }
command -v create-dmg >/dev/null || { red "create-dmg not installed — run 'brew install create-dmg'."; exit 1; }
command -v xcrun       >/dev/null || { red "xcrun not on PATH — install Xcode command line tools."; exit 1; }

# Notarization prerequisites. Catch these now, before a 2-minute build, rather
# than failing the notarytool submit after the DMG is already built.
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
    || { red "No 'Developer ID Application' cert for team $TEAM_ID in Keychain — releases must be notarized. See CLAUDE.md."; exit 1; }
# `notarytool history` makes a live API call, so a transient Apple outage looks
# identical to a bad profile — surface the real output instead of a flat claim.
if ! NOTARY_CHECK=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
    red "notarytool profile '$NOTARY_PROFILE' check failed (bad profile, or Apple's service is down — retry):"
    red "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>"
    echo "$NOTARY_CHECK"
    exit 1
fi

# Purchase-path contracts (see docs/licensing.md, "Payment-link contract").
# This release's binary points its Buy buttons at drobu.app/buy; already-
# shipped binaries point at the bare Stripe link. Both must be alive before
# anything ships — this also enforces "domain live before a binary that
# references it ships". Mirrors .github/workflows/payment-links-monitor.yml.
BUY_REDIRECT="https://drobu.app/buy"
STRIPE_LINK="https://buy.stripe.com/14A7sL2rkeKx6sj3QNdnW01"
BUY_OUT=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-redirs 0 --max-time 15 "$BUY_REDIRECT") || BUY_OUT="000 "
BUY_CODE=${BUY_OUT%% *}
BUY_TARGET=${BUY_OUT#* }
[[ $BUY_CODE == "302" ]] \
    || { red "$BUY_REDIRECT did not answer 302 (got '$BUY_CODE') — Buy buttons in this release would be dead. Configure the Cloudflare redirect first."; exit 1; }
[[ $BUY_TARGET == "$STRIPE_LINK" ]] \
    || { red "$BUY_REDIRECT redirects to '$BUY_TARGET', not the contract Payment Link — a hijacked or misconfigured redirect must not ship."; exit 1; }
STRIPE_BODY=$(mktemp)
STRIPE_OUT=$(curl -s -o "$STRIPE_BODY" -w '%{http_code} %{size_download}' --max-time 30 -A "Mozilla/5.0" "$STRIPE_LINK") || STRIPE_OUT="000 0"
STRIPE_CODE=${STRIPE_OUT%% *}
STRIPE_SIZE=${STRIPE_OUT#* }
{ [[ $STRIPE_CODE == "200" && $STRIPE_SIZE -gt 100000 ]] && grep -q "livemode" "$STRIPE_BODY"; } \
    || { rm -f "$STRIPE_BODY"; red "Stripe Payment Link is not serving the live checkout shell (code $STRIPE_CODE, ${STRIPE_SIZE} bytes) — old binaries' Buy buttons depend on it. Check the Stripe dashboard."; exit 1; }
rm -f "$STRIPE_BODY"
dig +short MX drobu.app | grep -q "mx.cloudflare.net" \
    || { red "drobu.app MX records missing — support@drobu.app (printed in the app) will bounce."; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ $BRANCH == "main" ]] || { red "Not on main (on $BRANCH)."; exit 1; }

# Only tracked-file changes block a release. Untracked files (debug scratch,
# in-progress docs, etc.) don't affect what gets built or published, so they
# get a note rather than a hard stop.
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    red "Tracked files have uncommitted changes — commit or stash first:"
    git status --porcelain --untracked-files=no
    exit 1
fi
UNTRACKED_COUNT=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
if [[ $UNTRACKED_COUNT -gt 0 ]]; then
    yellow "Note: $UNTRACKED_COUNT untracked file(s) present — not affecting the release."
fi

git pull --ff-only

VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
TAG="v$VERSION"

[[ -n $VERSION && -n $BUILD ]] || { red "Could not read version from $PLIST."; exit 1; }

if git rev-parse "$TAG" >/dev/null 2>&1; then
    red "Tag $TAG already exists. Bump version in $PLIST first."
    exit 1
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    red "Release $TAG already exists on GitHub. Bump version first."
    exit 1
fi

echo
echo "About to release:"
echo "  Version:  $VERSION"
echo "  Build:    $BUILD"
echo "  Tag:      $TAG"
echo "  Repo:     $REPO"
echo "  From SHA: $(git rev-parse --short HEAD) (on $BRANCH)"
echo
read -rp "Continue? [y/N] " yn
[[ $yn == [Yy]* ]] || { echo "Aborted."; exit 1; }

# --- Build --------------------------------------------------------------------

step "Building Drobu.app"
pkill -x Drobu 2>/dev/null || true
./build.sh

APP=".build/Drobu.app"
[[ -d $APP ]] || { red "Build did not produce $APP"; exit 1; }

# --- Notarize the app ---------------------------------------------------------
# Notarize + staple the .app FIRST so the ticket travels with the bundle even
# when Sparkle extracts it from the DMG on a client (a stapled DMG alone leaves
# the extracted app un-ticketed). The DMG is notarized + stapled separately below.
step "Notarizing Drobu.app (uploading to Apple — typically 1-3 min)"
NOTARIZE_ZIP=".build/Drobu-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
# Clean up the zip on the failure path too — set -e would otherwise skip the rm.
notarize "$NOTARIZE_ZIP" || { rm -f "$NOTARIZE_ZIP"; exit 1; }
rm -f "$NOTARIZE_ZIP"
step "Stapling notarization ticket to Drobu.app"
xcrun stapler staple "$APP"

# --- Package + sign -----------------------------------------------------------

step "Packaging DMG (create-dmg lays out the magical drag-to-Applications window)"
# Unversioned filename so the stable
#   https://github.com/<repo>/releases/latest/download/Drobu.dmg
# redirect resolves to the newest release without rewriting the website.
DMG="Drobu.dmg"
rm -f "$DMG"
create-dmg \
    --volname "Drobu" \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "Drobu.app" 130 180 \
    --app-drop-link 410 180 \
    --hide-extension "Drobu.app" \
    "$DMG" \
    ".build/Drobu.app"

step "Notarizing $DMG (uploading to Apple — typically 1-3 min)"
notarize "$DMG"
step "Stapling notarization ticket to $DMG"
# Stapling rewrites the DMG, changing its bytes — so this MUST happen before
# sign_update computes the Sparkle EdDSA signature and length below.
xcrun stapler staple "$DMG"
# Verify the notarization ticket is attached + valid before publishing.
# Do NOT add `spctl --assess --context primary-signature` here: the DMG container
# is notarized + stapled but intentionally NOT codesigned (only the app inside is),
# so spctl reports "no usable signature" and false-rejects a perfectly good DMG.
# `stapler validate` is the correct ticket check; Gatekeeper accepts a quarantined
# download on the strength of that stapled ticket.
xcrun stapler validate "$DMG" \
    || { red "Staple ticket missing/invalid on $DMG — aborting before publish."; exit 1; }

step "Signing DMG with Sparkle (Keychain prompt may appear)"
# sign_update prints `sparkle:edSignature="..." length="..."` on stdout
SIG_LINE=$("$SIGN_UPDATE" "$DMG")
ED_SIG=$(printf '%s\n' "$SIG_LINE" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
LENGTH=$(printf '%s\n' "$SIG_LINE" | sed -nE 's/.*length="([^"]+)".*/\1/p')

if [[ -z $ED_SIG || -z $LENGTH ]]; then
    red "Failed to parse sign_update output:"
    echo "$SIG_LINE"
    exit 1
fi

echo "  edSignature: ${ED_SIG:0:24}..."
echo "  length:      $LENGTH bytes"

# --- Tag + push ---------------------------------------------------------------

step "Tagging $TAG and pushing"
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

# From this point until the GitHub release is created, a failure leaves a
# pushed tag with no release attached. Print recovery on exit; clear the trap
# once the release exists.
cleanup_pushed_tag() {
    red ""
    red "✗ Release aborted after tag was pushed."
    red "  Clean up before re-running:"
    red "    git push --delete origin $TAG"
    red "    git tag -d $TAG"
}
# ERR: under `set -e` the shell exits after the trap runs. INT/TERM: a signal
# trap that RETURNS does not abort in Bash — so the signal handlers must exit
# explicitly (128 + signal number), or a Ctrl-C during the DMG upload would
# print the warning and then continue into release creation/appcast.
trap cleanup_pushed_tag ERR
trap 'cleanup_pushed_tag; exit 130' INT
trap 'cleanup_pushed_tag; exit 143' TERM

# --- GitHub release -----------------------------------------------------------

# Compose release notes from commits since the previous tag (if any).
PREV_TAG=$(git describe --tags --abbrev=0 --exclude="$TAG" 2>/dev/null || echo "")
if [[ -n $PREV_TAG ]]; then
    NOTES=$(git log --pretty=format:"- %s" "$PREV_TAG..HEAD" -- ':!website/public/appcast.xml')
    NOTES_HEADER="Changes since $PREV_TAG:"
else
    NOTES=$(git log --pretty=format:"- %s" -10 -- ':!website/public/appcast.xml')
    NOTES_HEADER="Initial release. Recent commits:"
fi

step "Creating GitHub release"
RELEASE_BODY=$(printf "%s\n\n%s\n" "$NOTES_HEADER" "$NOTES")
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "Drobu $VERSION" \
    --notes "$RELEASE_BODY"

# Release exists. Any later failure is appcast-only and recoverable without
# tag/release surgery, so drop the tag-cleanup trap.
trap - ERR

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG"
echo "  Download URL: $DOWNLOAD_URL"

# --- Appcast update -----------------------------------------------------------

step "Updating appcast.xml"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="$DOWNLOAD_URL" length="$LENGTH" type="application/x-apple-diskimage" sparkle:edSignature="$ED_SIG"/>
        </item>
EOF
)

# Insert the new <item> at the top of <channel> (newest first), preserving
# anything already in the appcast. Bail out cleanly if the stub is malformed.
python3 - "$APPCAST" "$NEW_ITEM" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
new_item = sys.argv[2]
xml = path.read_text()

# Find <channel>...</channel>
match = re.search(r"(<channel>)(.*?)(</channel>)", xml, re.DOTALL)
if not match:
    print("appcast.xml: missing <channel>...</channel>", file=sys.stderr)
    sys.exit(1)

inner = match.group(2)
# Title line must survive; we add item right after the last <title> line if
# present, otherwise just after <channel>.
title_match = re.search(r"(<title>.*?</title>)", inner)
if title_match:
    insertion_point = title_match.end()
    new_inner = inner[:insertion_point] + "\n" + new_item + inner[insertion_point:]
else:
    new_inner = "\n" + new_item + inner

xml = xml[:match.start(2)] + new_inner + xml[match.end(2):]
path.write_text(xml)
PY

step "Committing appcast"
git add "$APPCAST"
git commit -m "chore: appcast for $TAG"
git push

# --- Cleanup ------------------------------------------------------------------

rm -f "$DMG"

echo
green "✓ Released $TAG"
echo
echo "  Download URL: $DOWNLOAD_URL"
echo "  Appcast URL:  https://danieliusisiunas.github.io/drobu/appcast.xml"
echo "  GH release:   https://github.com/$REPO/releases/tag/$TAG"
echo
echo "GitHub Pages deploy takes ~1-2 min. Once live, an installed Drobu"
echo "will pick up the update on its next Sparkle check (or via Settings →"
echo "Check for Updates)."
