---
title: "feat: Discoverable crop corner handles"
type: feat
date: 2026-06-17
status: planned
execution: code
depth: lightweight
---

# feat: Discoverable crop corner handles

## Summary

Replace the crop overlay's currently-invisible edge-drag affordance with four
visible **corner handles**. Today the only way to crop a GIF / video / image is
to find an unmarked 10pt band along an edge — there is no visual cue that the
border is draggable, and the target is hard to hit. This plan adds corner grips
(L-shaped brackets) that are visible the moment edit mode opens, each one
reframing its two adjacent sides while the opposite corner stays anchored.

The change is confined to two files — the pure `CropGeometry` model and the
`CropOverlayView` overlay — so it covers image, GIF, and video crop uniformly
(all three editors mount the same overlay and need no edit). Save/export paths
are untouched.

---

## Problem Frame

The crop affordance is invisible and hard to grab (user report: *"the fact that
you can trim a video or gif is not noticeable and you have to really try to touch
on the edge of the image"*). `CropOverlayView` draws a dim + thin border + a
dimension pill, but nothing signals draggability, and interaction is gated on a
thin 10pt edge band (`nearestEdge` / `hitSlop`). Discoverability and ergonomics
both fail.

**Decided design (do not re-litigate): corners only.** Four corner grips, no
edge handles. A corner is a point target (easy to hit, unambiguous) and reframes
two sides at once. Any arbitrary crop rectangle remains reachable in at most two
corner drags (e.g. top-left then bottom-right).

---

## Requirements

- **R1.** The crop region's draggable affordance is visible on entering edit
  mode, across image / GIF / video editors.
- **R2.** Dragging a corner moves its two adjacent edges; the diagonally
  opposite corner stays fixed.
- **R3.** Corner drags inherit the existing clamps: whole-pixel rounding,
  per-axis minimum size (`minimumCropSize` = 20), and content-bounds clamping.
- **R4.** The release-critical sentinels are untouched: `isFullFrame` (integer
  exact, gates video passthrough-vs-re-encode) and `evenRoundedCropRect` (H.264
  even-dim flooring) keep identical semantics.
- **R5.** The overlay keeps its `hitTest` pass-through — clicks away from a
  handle fall through so window-drag-by-background and the player below keep
  working mid-frame.
- **R6.** Accessibility is preserved: the overlay stays an a11y group labeled
  "Crop area" with `readoutText` as its value, updated only when geometry
  actually changes.
- **R7.** New pure logic (`drag(corner:)`, `nearestCorner`) is unit-tested in
  the same commit; AppKit drawing / cursor wiring is not tested.

---

## Key Technical Decisions

- **Compose, don't reimplement.** `drag(corner:toContentPoint:)` calls the two
  existing, already-tested `drag(edge:)` clamps for that corner. The axes are
  independent, so order is irrelevant and per-axis min/bounds clamping is
  inherited for free. This keeps the corner mechanic provably consistent with
  the edge mechanic and adds almost no new clamping logic to test.
- **Keep `Edge` + `drag(edge:)`; remove `nearestEdge`.** `Edge` and
  `drag(edge:)` remain the internal building block for corner drags (and stay
  tested). `nearestEdge` becomes production-dead once the overlay switches to
  corners → remove it and migrate the handful of tests that reference it to
  `nearestCorner`. (Avoids leaving dead public API the maintainability pass
  would flag.)
- **Square (Chebyshev) hit test + Euclidean tie-break.** `nearestCorner` treats
  a corner as hit when the point is within `slop` on *both* axes (a generous
  square grab zone), and breaks ties by Euclidean distance, with declaration
  order (`topLeft, topRight, bottomLeft, bottomRight`) as the deterministic
  final tiebreaker — mirrors the determinism guarantee `nearestEdge` had.
- **Generous hit target.** Corner box slop ~18pt (vs today's 10pt edge band) —
  the point-shaped target plus the larger slop is the core ergonomic fix.
- **L-bracket visual.** Draw four corner brackets (≈3pt round-capped strokes,
  leg length clamped to ~`min(18, 0.4·cropW, 0.4·cropH)` so they never cross on
  tiny crops), white@0.95 with a subtle `NSShadow` so they read on light *and*
  dark content. Keep the existing dim + 2pt border + dimension pill. The
  actively-dragged corner's bracket draws in `controlAccentColor`. Remove the
  old per-edge active line.
- **Crosshair cursor.** macOS exposes **no** public diagonal-resize `NSCursor`,
  so corner zones use `.crosshair` (honest "grab this point" cue). Documented as
  a known limitation in the rules file.

---

## Implementation Units

### U1. Add corner geometry to `CropGeometry`

**Goal:** Pure model support for corner handles, composed from existing edge
clamps.

**Requirements:** R2, R3, R4, R7

**Dependencies:** none

**Files:**
- `Sources/DrobuCore/Services/CropGeometry.swift` (modify)
- `Tests/DrobuTests/CropGeometryTests.swift` (modify)

**Approach:**
- Add `enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }`.
- Add `mutating func drag(corner:toContentPoint:)` that switches on the corner
  and calls the two adjacent `drag(edge:)` clamps (topLeft → `.left` + `.top`,
  topRight → `.right` + `.top`, bottomLeft → `.left` + `.bottom`, bottomRight →
  `.right` + `.bottom`). Guard `isCroppable` (no-op otherwise), mirroring
  `drag(edge:)`.
- Add `func nearestCorner(atViewPoint:fittedRect:slop:) -> Corner?`: map crop
  rect to view space via `viewCropRect`, compute each corner anchor point, keep
  candidates within `slop` on both axes (square test), pick min Euclidean
  distance, ties resolve in declaration order.
- Remove `nearestEdge` (now production-dead). Keep `Edge` and `drag(edge:)`.
- Do **not** touch `isFullFrame`, `evenRoundedCropRect`, `fittedRect`,
  `contentPoint`, `viewCropRect`, `readoutText`, `isCroppable`.

**Patterns to follow:** the existing `drag(edge:)` clamping math and the
`nearestEdge` candidate/tie-break structure in the same file.

**Test scenarios** (`CropGeometryTests.swift`):
- `drag(corner: .topLeft, to: (20,30))` on 100×100 → cropRect `(20,30,80,70)`
  (two adjacent edges move).
- `drag(corner: .bottomRight, to: (60,70))` on 100×100 → `(0,0,60,70)` (opposite
  corner `topLeft` stays at origin / anchored).
- Min-size clamp both axes: `drag(corner: .topLeft, to: (95,95))` on 100×100 →
  width 20, height 20, maxX 100, maxY 100.
- Bounds clamp / restore: inset via `.topLeft` then `drag(corner: .topLeft, to:
  (-10,-10))` → back to full frame, `isFullFrame == true`.
- Two-corner expressiveness: `.topLeft → (10,15)` then `.bottomRight → (80,70)`
  → `(10,15,70,55)`.
- Whole-pixel rounding: `.topLeft → (10.6, 20.4)` → minX 11, minY 20.
- No-op when not croppable: 20×20 content, `drag(corner:)` leaves cropRect
  unchanged.
- `nearestCorner` within slop picks the right corner for each of the four
  corners (slop 18, 100×100).
- `nearestCorner` returns nil at center and at a mid-edge point far from any
  corner.
- `nearestCorner` tracks a moved crop rect (after a `.topLeft` inset, a point
  near the new top-left hits `.topLeft`; the old origin no longer does).
- `nearestCorner` tie-break determinism: on a 22×22 (croppable) crop, the center
  point — within square slop of all four corners — resolves to `.topLeft`.
- Migrate the too-small `nearestEdge` assertion in
  `tooSmallContentDisablesCropping` to `nearestCorner` (still nil).

**Verification:** `swift test` green; the corner suite asserts the anchor /
clamp / hit-test behavior above; `isFullFrame` and even-rounding tests unchanged
and passing.

### U2. Switch `CropOverlayView` interaction + drawing to corners

**Goal:** The overlay grabs corners (not edges), draws corner brackets, and
shows the crosshair cursor over corner zones.

**Requirements:** R1, R5, R6

**Dependencies:** U1

**Files:**
- `Sources/DrobuCore/Views/CropOverlayView.swift` (modify)

**Approach:**
- Replace `dragEdge: Edge?` with `dragCorner: Corner?`; bump `hitSlop`-style
  constant to a corner slop (~18pt).
- `hitTest` / `mouseDown`: use `geometry.nearestCorner(...)`; return nil away
  from corners (preserve pass-through — R5).
- `mouseDragged`: `geometry.drag(corner:toContentPoint:)` then
  `onGeometryChange`.
- `draw`: keep the dim + 2pt border + `drawReadoutPill`. Replace the per-edge
  active line with four corner L-brackets (leg length clamped per KTD, white@0.95
  + `NSShadow`); the active corner draws in `controlAccentColor`.
- `resetCursorRects`: add `.crosshair` over ~square zones centered on each
  corner (intersected with bounds), replacing the resize-band rects.
- Keep `isFlipped`, `acceptsFirstMouse = true`, `mouseDownCanMoveWindow = false`,
  the `geometry didSet` `!= oldValue` guard + cursor-rect invalidation, and the
  accessibility group/label/value wiring untouched (R6). The overlay still must
  not take first responder (Esc / Cmd+Return stay with `EditorKeyNSView`).

**Patterns to follow:** the existing draw/hit-test/cursor structure in
`CropOverlayView.swift`; `NSShadow` usage idioms; `TimelineScrubber` native
mouse-handling precedent referenced in the file header.

**Test scenarios:** none — AppKit drawing, hit-test wiring, and cursor rects are
explicitly out of unit-test scope (`testing-conventions.md`). Behavior is
exercised via U1's pure-geometry tests and the manual verification below.

**Verification:** build succeeds; manual verification (below) passes in all
three edit modes.

### U3. Capture the learnings (rules)

**Goal:** Record the two reusable gotchas for future media-editing work.

**Requirements:** —

**Dependencies:** U2

**Files:**
- `.claude/rules/media-editing-gotchas.md` (modify)

**Approach:** Append a short section covering (a) corner handles implemented as
composed edge clamps (opposite-corner anchoring, free per-axis clamping,
order-independent), and (b) macOS has no public diagonal-resize `NSCursor` →
`.crosshair` is the honest fallback for corner grips.

**Test expectation:** none — docs only.

---

## Behavior Matrix — corner → edges moved (opposite corner anchored)

| Corner        | Moves edges   | Anchored corner |
|---------------|---------------|-----------------|
| `topLeft`     | left + top    | bottomRight     |
| `topRight`    | right + top   | bottomLeft      |
| `bottomLeft`  | left + bottom | topRight        |
| `bottomRight` | right + bottom| topLeft         |

Each moved edge independently clamps to whole pixels, the per-axis 20px minimum,
and the content bounds (inherited from `drag(edge:)`).

---

## Manual Verification

Build + install + launch (`pkill -x Drobu; ./build.sh --install && open
/Applications/Drobu.app`), then for **each** of image, GIF, and video items:

1. Select the item, press **Cmd+Right** to enter edit mode.
2. Confirm four corner brackets are visible immediately, framing the media
   corners (full-frame initial state).
3. Drag a corner inward → its two adjacent sides move, the opposite corner stays
   put, the dimension pill updates, the active bracket turns accent-colored, and
   the cursor is a crosshair over the corner.
4. Drag a corner back out to the media edge → crop restores toward full frame.
5. Click-drag on the media *background* (away from any corner) → the floating
   panel still drags by background (pass-through intact).
6. **GIF/Video:** start a crop, then **Cmd+Return** to save → the cropped output
   is correct; an untouched (full-frame) Esc/save still records the original
   unchanged (isFullFrame path).
7. Tiny media (≤20px on an axis): brackets/handles are disabled and the
   "already at minimum" readout shows (unchanged behavior).

---

## Risks & Mitigations

- **Breaking the video passthrough gate.** `isFullFrame` / `evenRoundedCropRect`
  are release-critical. *Mitigation:* U1 does not touch them; existing tests for
  both stay and must pass.
- **Losing window-drag pass-through.** *Mitigation:* `hitTest` still returns nil
  away from corner zones; verified in manual step 5.
- **Tiny-crop bracket overlap.** Leg length clamps to a fraction of the crop
  size so brackets never cross. *Mitigation:* clamp formula in KTD; manual step 7.
- **Non-deterministic corner pick near a small crop's center.** *Mitigation:*
  Euclidean tie-break + declaration-order final tiebreak, unit-tested (U1).
- **Accessibility regression.** *Mitigation:* leave the a11y group/label/value
  wiring and the `!= oldValue` value-update guard untouched (R6).

---

## Scope Boundaries

**In scope:** corner-handle geometry + overlay drawing/interaction across all
three crop editors; rules capture.

**Out of scope (not goals):**
- Edge handles (explicitly dropped — corners only).
- Aspect-ratio locking, free-move of the whole crop rect, keyboard nudging,
  rule-of-thirds grid.
- Any change to save/export pipelines, the trim scrubber, or the editors
  themselves.

**Deferred to follow-up (rides the next release, not this PR):** the version
bump for this user-facing polish. Per CLAUDE.md this is a **PATCH**; recommended
**1.9.3 / build 17** (clean per-feature version line) over folding into the
held-unreleased 1.9.2. The bump touches `Sources/DrobuCore/Info.plist`
(`CFBundleShortVersionString` + `CFBundleVersion`),
`website/src/components/DownloadCTA.astro`, and
`website/src/components/Footer.astro` — done at release time so the website never
advertises an undownloadable version while the release is held.
