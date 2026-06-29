#!/usr/bin/env bash
#
# web-media.sh — turn a marketing GIF (or screen recording) into web-optimized
# assets for the Drobu website: an MP4 (H.264) + WebM (VP9) for an autoplaying
# <video>, plus a still poster frame (WebP) for instant first paint and the
# prefers-reduced-motion fallback.
#
# Why video instead of the raw GIF: a ~1MB GIF becomes ~100-150KB of MP4/WebM,
# plays smoother, can be paused, and respects "reduce motion". Output is
# self-hosted in website/public/media (no CDN — matches the privacy stance).
#
# Usage:
#   tools/web-media.sh "Resources/Marketing gifs/image-crop.gif"        # one file
#   tools/web-media.sh                                                   # all GIFs in Resources/Marketing gifs/
#
# Then in the .astro section, swap <Showcase> from the GIF <img> to the video
# variant (pass mp4/webm/poster). Re-run any time the source capture changes.
#
# Requires ffmpeg:  brew install ffmpeg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/Resources/Marketing gifs"
OUT_DIR="$REPO_ROOT/website/public/media"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found. Install it once with:  brew install ffmpeg" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

convert_one() {
  local gif="$1"
  [ -f "$gif" ] || { echo "skip (not found): $gif" >&2; return; }
  local base; base="$(basename "${gif%.*}")"
  echo "==> $base"

  # H.264 MP4. yuv420p + even dimensions are required for broad playback.
  ffmpeg -y -loglevel error -i "$gif" \
    -movflags +faststart -pix_fmt yuv420p \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -crf 23 -preset slow -an \
    "$OUT_DIR/$base.mp4"

  # VP9 WebM (smaller still on supporting browsers).
  ffmpeg -y -loglevel error -i "$gif" \
    -c:v libvpx-vp9 -crf 34 -b:v 0 -an \
    "$OUT_DIR/$base.webm"

  # Poster: first frame, WebP. Serves as the LCP image and the reduced-motion still.
  ffmpeg -y -loglevel error -i "$gif" -frames:v 1 \
    "$OUT_DIR/$base.webp"

  echo "    $(cd "$OUT_DIR" && ls -lh "$base".{mp4,webm,webp} | awk '{print $9": "$5}' | tr '\n' '  ')"
}

if [ "$#" -ge 1 ]; then
  for f in "$@"; do convert_one "$f"; done
else
  shopt -s nullglob
  for f in "$SRC_DIR"/*.gif; do convert_one "$f"; done
  shopt -u nullglob
fi

echo "Done. Assets in website/public/media/"
