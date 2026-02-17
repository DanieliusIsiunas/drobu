# GIF Support Brainstorm

**Date:** 2026-02-17
**Status:** Ready for planning

## Vision

Replace the clunky Giphy workflow (record → save → find file → edit → copy) with a clipboard-native experience: capture → edit → paste. The clipboard IS the hub. Mobile-phone-like media capture on desktop — everything at your fingertips, no app switching.

### Three Phases

1. **GIF Preview** (immediate) — Capture, display, and paste animated GIFs
2. **GIF Editing** (future) — Trim, speed adjustment, inline in the panel
3. **GIF Screen Capture** (future) — Built-in screen recording that outputs GIFs directly into clipboard history

## Phase 1: GIF Preview — Key Decisions

### GIF as a distinct kind
- New `kind = "gif"` in ClipboardRecord (not reusing "image")
- Clean separation for future editing features
- Row view shows "GIF" label, preview knows to animate

### Clipboard capture priority
- `text > gif > image` (GIF checked before PNG/TIFF fallback)
- Pasteboard type: `com.compuserve.gif`
- 20MB size cap (vs 10MB for static images)

### Animated preview rendering
- **Phase 1:** NSImageView wrapper (`NSViewRepresentable`) with `animates = true`
- Zero dependencies, native macOS GIF animation support
- **Phase 2 (future):** Switch to CGImageSource for frame-level control when editing is needed

### Metadata display
- Row: `GIF: 320x240 (1.2 MB, 3.2s)`
- Preview metadata bar: dimensions, file size, duration, frame count
- Duration/frame count extracted via CGImageSource (read-only, not for rendering)

### Paste behavior
- Write BOTH `com.compuserve.gif` AND static PNG to pasteboard
- Apps that understand GIF (Slack, Discord, browsers) get animation
- Apps that don't (TextEdit, Pages) get a still image
- Best compatibility across the ecosystem

## Competitive Landscape

- **Gifox** (gifox.app) — Menu bar GIF capture + editor. Closest UX benchmark. Standalone app, not clipboard-integrated.
- **Gifski** (sindresorhus, open source) — Video → high-quality GIF converter. Rust encoder (pngquant). Relevant for Phase 3 encoding.
- **Giphy Capture** — Abandoned since 2017. Not a reference.

Key differentiator: No one integrates GIF capture/edit into clipboard workflow. This is a unique position.

## Files Affected (Phase 1)

| File | Change |
|------|--------|
| `ClipboardRecord.swift` | Add `kindGif = "gif"` constant |
| `ClipboardMonitor.swift` | Check `com.compuserve.gif` before PNG/TIFF, 20MB cap |
| `PreviewPanel.swift` | Add GIF preview branch using AnimatedGIFView |
| New: `AnimatedGIFView.swift` | NSViewRepresentable wrapping NSImageView with `animates = true` |
| `ClipboardRowView.swift` | GIF row label: dimensions, size, duration |
| `FloatingPanel.swift` (or paste logic) | Dual-format paste: GIF data + PNG fallback |

## Open Questions (for future phases)

- **Phase 2:** Should trim UI be a timeline scrubber or frame-by-frame stepper?
- **Phase 3:** ScreenCaptureKit vs CGWindowListCreateImage for recording? Gifski encoder vs ImageIO for GIF encoding?
- **Phase 3:** Global hotkey for "start/stop capture" — separate from main panel hotkey?
- **Storage:** Should Phase 3 recordings go to disk (file reference in DB) instead of SQLite blob?

## Next Step

Run `/workflows:plan` to create implementation plan for Phase 1.
