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
