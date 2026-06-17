# Media Editing Gotchas (crop/trim suite)

Learned building the spatial-crop feature (v1.4). These apply to any future work on
the GIF/video/image editing pipelines.

## Pixel space: `CGImage.width/height`, never `NSImage.size`

`NSImage.size` returns logical points (resolution-metadata dependent). Crop math in
content pixels — especially rects fed to `CGImage.cropping(to:)` — must come from
`CGImage.width/height` (or `AVAssetTrack.naturalSize` for video). Seeding from
`NSImage.size` on Retina media produces a crop covering only a quarter of the real
pixel grid. Drobu's own captures are 1x (`captureResolution = .nominal`), but pasted
media can be 2x — never assume 1x. `CropGeometry` owns the view-points ↔
content-pixels mapping (two hops: view → aspect-fit rect → pixels).

## AVFoundation crop composition

- `AVAssetExportPresetPassthrough` **ignores** `videoComposition` entirely — a crop
  requires a re-encoding preset (`AVAssetExportPresetHighestQuality`).
- The composition's layer-instruction space is **top-left origin** (SDK header doc):
  `renderSize` = crop size + `setTransform(translate(-cropOrigin))` crops correctly
  with no Y-flip for upright sources. Verified by pixel-content tests in
  `VideoCropExporterTests` (white/dark quadrant luma assertions).
- The `AVMutableVideoCompositionInstruction.timeRange` must span the **full asset
  duration**; `session.timeRange` does the trimming. A narrower instruction range
  produces blank frames.
- H.264 requires **even dimensions**: floor crop width/height to even
  (`CropGeometry.evenRoundedCropRect`) or the encode fails / produces a garbage edge.
- The modern export API (`export(to:as:)`, `states()`) is macOS 15+; on the macOS 14
  floor use the property-based `await session.export()` + `status` pattern
  (deprecation warnings on newer SDKs are expected and accepted).

## CGImageSource: header-only gating vs full decode

`CGImageSourceCopyPropertiesAtIndex` reads container metadata without decoding
pixels — the right check for hot paths (the Cmd+Right gate runs on the main thread
per keypress). `CGImageSourceCreateImageAtIndex` is a full pixel decode (megabytes
for a screenshot) — only call it where the pixels are needed, off the main actor for
large images. Pair the cheap gate with a graceful late-failure path: header-valid
but undecodable data must exit edit mode, not strand a spinner.

## Overlay over players: `hitTest` pass-through

To layer an interactive NSView over `GIFPlayerNSView`/`AVPlayerView`, override
`hitTest` to return `nil` except where the overlay genuinely claims clicks (edge
slop bands). Events then fall through to the player/window — window
drag-by-background keeps working mid-frame. Required companions:
`acceptsFirstMouse = true`, `mouseDownCanMoveWindow = false` (the TimelineScrubber
idiom). The overlay must NOT take first responder; Esc/Cmd+Return stay with the
host editor's key view (`EditorKeyNSView`).

## Swift 6: wrapper structs around CGImage need explicit `Sendable`

`CGImage` carries the SDK's `Sendable` conformance, but a wrapper struct
(`GIFFrame`) is not implicitly Sendable — add the one-word conformance to cross
`Task.detached`. Never `@unchecked Sendable` (the contents are genuinely sendable).

## AVFoundation Sendable annotations differ by SDK — CI compiles stricter than local

A newer local SDK (macOS 26.x) carries `sending`/Sendable annotations that older
CI SDKs (Xcode 16.4 / macOS 15.5) lack. Concretely: `async let tracks =
asset.loadTracks(...)` inside a `@MainActor` task compiles locally but fails on CI
with *"non-sendable result type `[AVAssetTrack]` cannot be sent from nonisolated
context"*. A green local `swift build` does NOT prove CI compiles.

**Pattern:** never let non-Sendable AVFoundation types (`AVAssetTrack`,
`AVMutable*`) cross an actor boundary. Do the whole load/composition in one
nonisolated function (e.g. `VideoCropExporter.loadEditorMetadata`) and return only
Sendable values (`Double`, `CGSize`) to the view. Plain sequential `await` inside
the nonisolated region is fine; `async let` from actor context is the trap.

## Detached saves outlive the edit session

`Task.detached` exports/encodes are not cancelled when the panel closes. Save
callbacks must tolerate firing after edit mode ended: `commitMediaEdit` /
`saveVideoTrim` guard on `isEditing` — and any path that produced a temp FILE must
clean it up in that guard (the video early-return deletes the orphaned export).
The panel must stay visible during video exports (cleanup deferral is gated on
panel visibility), and `FloatingPanel.resignKey` closes the panel — the residual
race is documented in the v1.4 review artifacts.

## Crop handles: corner grips as composed edge clamps (v1.9.x)

The crop overlay (`CropOverlayView`) exposes **corner handles only** — four
L-bracket grips, no edge handles. The discoverability problem they fixed: the
prior edge-drag affordance was invisible (only a dim + thin border), gated on a
thin 10pt edge band, so users couldn't tell the crop was draggable or where to
grab. Corners are a point target (easy to hit, unambiguous) and reframe two sides
at once; any rectangle is reachable in at most two corner drags.

- **Implement a corner drag as the composition of its two adjacent edge clamps**,
  not as new geometry. `CropGeometry.drag(corner:toContentPoint:)` calls
  `drag(edge: .left/.right)` + `drag(edge: .top/.bottom)` for that corner. The
  diagonally opposite corner stays anchored for free, and whole-pixel rounding +
  per-axis `minimumCropSize` + bounds clamping are all inherited from the
  already-tested `drag(edge:)`. The two axes are independent, so the order of the
  two edge drags is irrelevant. This kept the release-critical `isFullFrame`
  sentinel and `evenRoundedCropRect` (H.264 even-dim floor) **untouched** — corner
  drags route through the same clamps the video passthrough branch already trusts.
- `nearestCorner` uses a **square (Chebyshev) hit test** (within `slop` on BOTH
  axes — a generous grab zone, ~18pt vs the old 10pt edge band) and breaks ties by
  **Euclidean distance, then declaration order** (topLeft, topRight, bottomLeft,
  bottomRight) so a click equidistant from multiple corners on a tiny crop is
  deterministic, not probabilistic. Pure + unit-tested in `CropGeometryTests`.
- **There is no public diagonal-resize `NSCursor`** (no
  `resizeNorthWestSoutheast`-style member). For corner grips, `.crosshair` is the
  honest public cue ("grab this point"); the private `_windowResize*` selectors
  exist but are fragile and unnecessary here. Cursor zones are square rects
  centered on each corner, matching `nearestCorner`'s slop.
- Bracket **leg length is `min(handleLegMax, min(cropW, cropH) · 0.4)`** — the 0.4
  factor (2 × 0.4 < 1) guarantees the two legs sharing an edge never cross, even on
  a tiny crop. **Do NOT add a fixed floor** (an earlier `max(6, …)` floor *defeated*
  that guarantee: when `0.4·side < 6` the floor forced 6pt legs that crossed on a
  sub-12pt displayed crop — reachable with 2x pasted media or large content shown
  small). Legs shrink proportionally on small crops; that's correct.
- **Keep the corner grab slop CONSTANT — do NOT scale it down with crop size.** It's
  tempting to clamp the slop to `min(cornerSlop, minSide/2)` so adjacent zones never
  overlap, but that backfires: a valid near-minimum crop of high-res media is
  displayed only a few points wide, so the clamp shrinks the grab target to ~1–2pt
  and the user **cannot re-grab a corner to enlarge it** — defeating the feature
  (caught by Codex on PR #60, after it was shipped as a "fix"). A usable target beats
  non-overlapping zones. With a constant 18pt slop the four zones overlap once the
  crop is displayed smaller than `2·cornerSlop`, but `nearestCorner` resolves the
  click to the proximate corner and at that size the corners are near-coincident
  anyway — a deterministic, accepted nuance, not a defect.
- **Capture a grab offset on mouseDown** (`anchor − clickPoint`) and add it back on
  mouseDragged, or the corner teleports to the cursor on the first drag delta — the
  jump scales with the slop times the content/view zoom, so it's worst on high-res
  media shown small.
- The corner→point mapping lives in **one** place — `CropGeometry.Corner.point(in:)`
  — shared by `nearestCorner`, `resetCursorRects`, and `drawCornerHandles` (the draw
  site additionally derives inward `dx`/`dy` from the corner). `Corner.allCases`
  declaration order doubles as the deterministic tie-break order in `nearestCorner`.
- Shadow: use an **offset-free** blur halo (`shadowOffset = .zero`), not a directional
  drop shadow. `NSShadow.shadowOffset` is interpreted in the (flipped) context's
  coordinate space, so a directional offset both inverts visually and is a trap; a
  zero-offset halo reads on light AND dark content and sidesteps the flip entirely.
- The change is interaction + drawing only — the three editors (Image/GIF/Video)
  mount the same overlay and needed no edit.
