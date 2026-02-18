# GIF Screen Capture (Phase 3) Brainstorm

**Date:** 2026-02-18
**Status:** Ready for planning
**Depends on:** Phase 1 (GIF Preview) — completed, Phase 2 (GIF Trim Editing) — completed

## What We're Building

Built-in screen region recording that outputs GIFs directly into clipboard history. Press a global hotkey, drag a region, recording starts immediately. Press the hotkey again to stop — the GIF is encoded, saved to the database, and written to the pasteboard ready to paste. No app switching, no file management.

**Scope: Region capture only.** Window capture, full-screen capture, and advanced settings UI deferred to future iterations.

## Why This Approach

- **Single hotkey, zero UI** — fastest possible workflow. Press, drag, record, press, paste. No preview step, no save dialog.
- **GIFFrameEngine reuse** — the Phase 2 encoder already handles `[GIFFrame] → Data`. Screen capture just feeds it CGImages from ScreenCaptureKit instead of extracting them from existing GIF data.
- **Phase 2 trim editor as post-processor** — no need to build preview/trim into the capture flow. User captures, it saves immediately. If they need to trim, they open the panel and use the existing trim editor.
- **ScreenCaptureKit** — modern Apple API (available since macOS 12.3, app targets macOS 14+). Provides `SCStream` for efficient frame capture with content filters. No legacy APIs needed.
- **ImageIO encoding** — zero new dependencies. Quality is good enough for UI demos and bug reports. Gifski can be added later if quality becomes a priority.

## Key Decisions

### Capture mode
- **Region only** for MVP. User drags a rectangle, records that area.
- No window detection, no full-screen mode. Covers 90% of GIF use cases (UI demos, bug reports, quick tutorials).

### Recording trigger and control
- **Single global hotkey** toggles the entire flow:
  1. Press hotkey → full-screen transparent overlay appears for region selection
  2. Drag to draw rectangle → recording starts immediately
  3. Press hotkey again → recording stops, encodes, saves
- No floating HUD, no recording button. The hotkey is the only control.
- Small recording indicator (red dot / border pulse on the selected region) so user knows it's active.

### Output pipeline
- **Clipboard + database.** When recording stops:
  1. Encode frames via `GIFFrameEngine.encodeFrames()`
  2. Save to DB as `kind = "gif"` via `ClipboardRecord.upsert()`
  3. Write to pasteboard (GIF + PNG fallback, same as Phase 1 paste)
  4. User can immediately Cmd+V to paste
- The `ClipboardMonitor` must suppress picking up the pasteboard write (same suppression pattern as pasting from the panel).

### Post-capture flow
- **Save immediately.** No preview, no trim step, no discard dialog.
- Bad takes? Delete from the panel or just record again.
- Need to trim? Open the panel, select the GIF, right-arrow into the Phase 2 trim editor.

### Capture settings (defaults)
- **10 fps** — smooth enough for UI demos, keeps file size reasonable
- **15 second max** — auto-stops recording at 15s to prevent runaway captures
- **1x resolution** — captures at logical pixels, not Retina 2x, to keep GIF file sizes manageable (~5-15MB typical)
- Settings configurable in the Settings view (future enhancement, hardcoded for MVP)

### GIF encoder
- **GIFFrameEngine (ImageIO)** — zero new dependencies, already proven in Phase 2
- The `encodeFrames()` method accepts any `[GIFFrame]` — screen capture frames slot right in
- Extension needed: frame downscaling utility (screen captures may need resizing before encoding)

### Hotkey
- **Separate global hotkey** from the panel toggle (Cmd+Shift+V)
- Default: TBD during planning (candidates: Cmd+Shift+G, Cmd+Shift+5, Ctrl+Shift+G)
- Uses the same `HotKey` library pattern — second `HotKey?` instance in AppDelegate
- New `CaptureHotkeyDefaults` following the existing `HotkeyDefaults` pattern
- Hotkey recorder added to Settings view

### Permissions
- **Screen Recording permission** required (ScreenCaptureKit)
- Add `NSScreenCaptureUsageDescription` to Info.plist
- Permission check on first capture attempt (same pattern as Accessibility check)
- Alert guiding user to System Settings > Privacy & Security > Screen Recording

### Storage
- **Same SQLite BLOB storage** as clipboard-copied GIFs
- 20MB cap applies (10fps × 15s × ~50KB/frame ≈ 7.5MB typical, well within limits)
- If captures routinely exceed 20MB, raise the cap or add file-reference storage later
- Existing cleanup/retention policies apply normally

## Architecture Sketch

```
Global Hotkey Press
    → ScreenCaptureService.startRegionSelection()
    → RegionSelectionPanel (transparent overlay, drag to draw rect)
    → User releases mouse → recording starts
    → SCStream captures frames at 10fps → appends to [GIFFrame] buffer
    → (frames downscaled to 1x if Retina)

Global Hotkey Press Again (or 15s auto-stop)
    → SCStream stops
    → GIFFrameEngine.encodeFrames(buffer) → Data
    → ClipboardRecord.upsert(kind: "gif", imageData: gifData)
    → Pasteboard write (GIF + PNG fallback)
    → ClipboardMonitor.suppressNextChange()
    → Done — user can Cmd+V immediately
```

## New Components Needed

1. **ScreenCaptureService** — manages SCStream lifecycle, frame collection, encoding trigger
2. **RegionSelectionPanel** — transparent full-screen NSPanel for drag-to-select
3. **CaptureHotkeyDefaults** — UserDefaults wrapper for capture hotkey
4. **Frame downscaling utility** — resize CGImages from Retina to 1x before encoding

## Files Affected

| File | Change |
|------|--------|
| `Sources/Services/ScreenCaptureService.swift` | **New** — SCStream management, frame collection, encoding |
| `Sources/Views/RegionSelectionPanel.swift` | **New** — transparent overlay for area selection |
| `Sources/Models/CaptureHotkeyDefaults.swift` | **New** — UserDefaults for capture hotkey |
| `Sources/Services/GIFFrameEngine.swift` | Edit — add frame downscaling utility |
| `Sources/App/AppDelegate.swift` | Edit — second hotkey, capture service init, permission check |
| `Sources/Views/SettingsView.swift` | Edit — capture hotkey recorder |
| `Sources/Info.plist` | Edit — add `NSScreenCaptureUsageDescription` |

## Open Questions (for planning)

- What default hotkey? Need one that doesn't conflict with macOS screenshot (Cmd+Shift+3/4/5) or the panel toggle (Cmd+Shift+V)
- Recording indicator: subtle red border around the region? Pulsing dot in menu bar? Both?
- Should the region selection remember the last used rect (for repeated captures of the same area)?
- Mouse cursor: include in the capture or exclude? ScreenCaptureKit supports both.
- Audio: ignore entirely for GIF? (Yes for MVP, but worth noting)

## Competitive Reference

- **Gifox** (gifox.app) — closest UX. Global hotkey → region select → record → stop → saves as file. We do the same but output goes to clipboard history instead of a file.
- **macOS Screenshot** (Cmd+Shift+5) — has screen recording, but outputs MOV files, not GIFs. No clipboard integration.
- **Kap** (open source, getkap.co) — Electron-based screen recorder. Good UI but heavy, not clipboard-integrated.

Key differentiator: no one puts screen→GIF directly into a clipboard manager. Capture→trim→paste, all in one tool.

## Next Step

Run `/workflows:plan` to create implementation plan.
