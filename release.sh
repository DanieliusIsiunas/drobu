#!/usr/bin/env bash
# Cuts a Drobu release end-to-end:
#   1. Reads version from Info.plist
#   2. Builds and code-signs the app
#   3. Zips Drobu.app (preserving framework symlinks via ditto)
#   4. Signs the zip with Sparkle (reads private key from Keychain)
#   5. Tags the commit and pushes
#   6. Creates a GitHub Release with the zip attached
#   7. Updates website/public/appcast.xml with the new <item>
#   8. Commits + pushes the appcast (GH Pages picks it up automatically)
#
# Bump the version in Info.plist (CFBundleShortVersionString + CFBundleVersion)
# and commit that on main before running this script.
#
# Reversible if any step fails: tag/release/appcast commits can be deleted
# manually; the local zip is removed at the end either way.

set -euo pipefail

cd "$(dirname "$0")"

REPO="DanieliusIsiunas/drobu"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
PLIST="Sources/DrobuCore/Info.plist"
APPCAST="website/public/appcast.xml"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
step()   { printf '\033[36m→ %s\033[0m\n' "$*"; }

# --- Pre-flight ---------------------------------------------------------------

[[ -x $SIGN_UPDATE ]] || { red "sign_update not at $SIGN_UPDATE — run ./build.sh once to fetch Sparkle artifacts."; exit 1; }
command -v gh    >/dev/null || { red "gh CLI not installed."; exit 1; }
command -v plutil >/dev/null || { red "plutil not on PATH."; exit 1; }

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

# --- Package + sign -----------------------------------------------------------

step "Packaging zip (ditto preserves Sparkle framework symlinks)"
# Unversioned filename so the stable
#   https://github.com/<repo>/releases/latest/download/Drobu.zip
# redirect resolves to the newest release without rewriting the website.
ZIP="Drobu.zip"
rm -f "$ZIP"
(cd .build && ditto -c -k --keepParent Drobu.app "../$ZIP")

step "Signing with Sparkle (Keychain prompt may appear)"
# sign_update prints `sparkle:edSignature="..." length="..."` on stdout
SIG_LINE=$("$SIGN_UPDATE" "$ZIP")
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
trap cleanup_pushed_tag ERR

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
gh release create "$TAG" "$ZIP" \
    --repo "$REPO" \
    --title "Drobu $VERSION" \
    --notes "$RELEASE_BODY"

# Release exists. Any later failure is appcast-only and recoverable without
# tag/release surgery, so drop the tag-cleanup trap.
trap - ERR

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"
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
            <enclosure url="$DOWNLOAD_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
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

rm -f "$ZIP"

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
