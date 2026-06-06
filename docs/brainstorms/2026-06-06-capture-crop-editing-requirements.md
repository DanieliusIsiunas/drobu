---
date: 2026-06-06
topic: capture-crop-editing
---

# Crop in the Capture Editing Suite — Requirements

## Summary

Add spatial crop to the inline edit mode (Cmd+Right): drag any edge of the displayed frame to cut away unwanted capture area, with a live dimension readout in output pixels. Crop works on GIFs, videos, and still images; saving bakes the crop into the stored content with the same Cmd+Return / Esc conventions as trim.

---

## Problem Frame

Region selection happens before recording starts, but the content that matters can appear mid-recording — a popup that isn't on screen yet can't be framed. Recording one took several re-record attempts, each a miss; the eventual workaround was deliberately over-capturing a larger area to guarantee the elements landed in frame, junk background included.

Post-hoc crop turns that workaround into a workflow: capture generously, crop precisely afterwards. The capture-time selector can never solve this. Trim already covers the time axis; crop covers the spatial one.

---

## Key Decisions

- **Inline edit mode is the crop home.** Crop handles overlay the player inside the existing edit-mode view (entered with Cmd+Right), next to the trim scrubber. One consistent editing surface; the small preview pane gives coarse precision, which is acceptable for cutting background junk. Large-preview editing and a dedicated fullscreen crop overlay were considered and rejected as heavier.
- **Edge-drag only.** Four draggable edges with a live readout. No corner handles, no repositioning drag, no aspect lock — any rect is reachable by dragging edges individually.
- **Destructive save, like trim.** Saving replaces the record's content with the cropped result. No crop metadata, no re-crop later.
- **One edit session for GIF/video.** Crop and trim coexist; a single Cmd+Return applies both, Esc discards both.
- **Video re-encodes only when cropped.** A trim-only save keeps today's instant lossless passthrough export; applying a crop switches that save to a real re-encode.

---

## Requirements

**Crop interaction**

- R1. In edit mode, the displayed frame shows four draggable edges; dragging an edge inward shrinks the crop rect on that side.
- R2. A live dimension readout shows the resulting output size in content pixels (not view points) while dragging.
- R3. The crop rect cannot shrink below a minimum size, matching the capture-time 20×20px region minimum.
- R4. Drags are clamped to the frame bounds, and any edge can be re-adjusted outward again before saving.

**Content types**

- R5. GIF: the saved GIF has every frame cropped to the rect, preserving per-frame delays and the selected trim range.
- R6. Video: the saved MP4 is cropped to the rect. Trim-only saves keep the passthrough export; cropped saves re-encode.
- R7. Still images: entering edit mode on an image record opens a crop-only editor (no timeline) — images gain edit mode for the first time.
- R8. File-copy records are excluded: crop is only offered for records whose image data lives inside Drobu; user files on disk are never modified.

**Save and cancel semantics**

- R9. Cmd+Return saves: the cropped (and, for GIF/video, trimmed) content replaces the record via the existing upsert path, moving it to the top of history.
- R10. Esc discards all pending edit-session changes — crop and trim — and exits edit mode with the record untouched.
- R11. A save with untouched crop edges behaves exactly as today — no spurious re-encode for video, no quality churn.

**Accessibility**

- R12. The crop editor follows the project accessibility conventions (`.claude/rules/accessibility.md`): edges and readout are VoiceOver-discoverable with labels, and dynamic values update as the crop changes.

---

## Key Flows

- F1. Crop a GIF with junk background
  - **Trigger:** User selects a GIF capture and presses Cmd+Right to enter edit mode.
  - **Steps:** Edit view opens with the trim scrubber and crop edges at the frame bounds; user drags the left and top edges inward, watching the readout; looping playback shows the framing; Cmd+Return saves.
  - **Outcome:** Record holds the cropped GIF (smaller file), at the top of history.
  - **Covers:** R1, R2, R5, R9

- F2. Crop and trim a video in one session
  - **Trigger:** User edits a video capture.
  - **Steps:** User narrows the time range on the scrubber and drags two edges inward; Cmd+Return runs a single cropped re-encode of the trimmed range.
  - **Outcome:** One save produces the trimmed, cropped MP4.
  - **Covers:** R1, R6, R9

- F3. Crop a screenshot
  - **Trigger:** User selects a still-image record and presses Cmd+Right to enter edit mode.
  - **Steps:** Crop-only editor opens (no timeline); user adjusts edges; Cmd+Return saves.
  - **Outcome:** Record holds the cropped image.
  - **Covers:** R7, R9

- F4. Abandon an edit
  - **Trigger:** User has dragged crop edges (and possibly trim handles), then presses Esc.
  - **Outcome:** Edit mode closes; record unchanged.
  - **Covers:** R10

---

## Acceptance Examples

- AE1. **Covers R6, R11.** Given a video record, when the user trims only (never touches crop edges) and saves, then the export uses passthrough and completes near-instantly as today.
- AE2. **Covers R6.** Given a video record, when the user crops (with or without trim) and saves, then the saved MP4's dimensions equal the crop rect and the export re-encodes.
- AE3. **Covers R3.** Given a crop drag that would make the rect smaller than the minimum, when the user keeps dragging, then the edge stops at the minimum and the readout shows the clamped size.
- AE4. **Covers R8.** Given a file-copy record displaying an image preview, when the user attempts edit mode, then crop is not offered and the file on disk is untouched.
- AE5. **Covers R5.** Given a GIF trimmed to frames 10–30 and cropped, when saved, then the output contains only frames 10–30, each cropped, with original per-frame delays.

---

## Scope Boundaries

Deferred for later:

- Corner handles, dragging the rect to reposition, aspect-ratio lock
- Non-destructive crop (stored as metadata, re-croppable later)
- Zoom or magnifier for pixel-precise cropping in the small pane
- Crop for file-copy records

---

## Dependencies / Assumptions

- A cropped-video save taking a few seconds (re-encode) is acceptable; whether it needs a progress indicator is a planning question.
- Cropping shrinks GIF file size, which also reduces hits on the existing too-large-GIF half-framerate fallback.
- The existing edit-mode container can host a crop overlay above the player without disturbing playback.

---

## Success Criteria

- The popup scenario works end-to-end: over-capture, crop to the popup, paste the cropped result.
- Crop geometry and pipeline logic (rect clamping, coordinate mapping, frame cropping) ship with `swift test` coverage in the same commit, per testing conventions.
- Trim-only saves are behaviorally unchanged.

---

## Outstanding Questions

Deferred to planning:

- Handle hit-target size and visual style for edges in the small pane.
- Whether the cropped-video export needs a progress/spinner state in the edit view.
- Where the dimension readout sits (over the frame vs in the metadata bar).

---

## Sources

- Trim UI: `Sources/DrobuCore/Views/GIFTrimView.swift`, `Sources/DrobuCore/Views/VideoTrimView.swift`; scrubbers: `Sources/DrobuCore/Views/TimelineScrubber.swift`, `Sources/DrobuCore/Views/VideoTimelineScrubber.swift`.
- Re-encode pipelines: `Sources/DrobuCore/Services/GIFFrameEngine.swift` (frame extract/encode); `AVAssetExportSession` passthrough export in `Sources/DrobuCore/Views/VideoTrimView.swift`.
- Drag-rect overlay precedent: `Sources/DrobuCore/Views/RegionSelectionPanel.swift` (capture-time region selection, 20×20 minimum, live dimension label).
- Edit-mode entry and save callbacks: `Sources/DrobuCore/Views/PreviewPanel.swift`.
- Prior art: `docs/plans/2026-02-17-feat-gif-trim-editing-plan.md`, `docs/plans/2026-03-29-feat-video-trim-plan.md`.
