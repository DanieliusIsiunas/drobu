---
title: Video Trim
type: feat
date: 2026-03-29
---

# Video Trim

## Overview

Add inline video trimming that mirrors the existing GIF trim UX. Right arrow on a video item enters trim mode with a timeline scrubber (start/end handles), playback constrained to the selected range, and Cmd+Return/Escape to save/discard. Uses `AVAssetExportSession` with `.passthrough` for lossless, fast trimming.

## Pattern: Exact Mirror of GIF Trim

The GIF trim architecture has 3 views + 2 integration points:

| GIF | Video (new) | Key difference |
|-----|-------------|----------------|
| `GIFTrimView.swift` (96 lines) | `VideoTrimView.swift` | Time-based (CMTime) instead of frame indices |
| `GIFTrimPlayerView.swift` (137 lines) | `VideoTrimPlayerView.swift` | AVPlayer instead of CALayer + per-frame timer |
| `TimelineScrubber.swift` (191 lines) | `VideoTimelineScrubber.swift` | Maps seconds to pixels instead of frame indices |
| PreviewPanel: `gifPreview(for:)` | PreviewPanel: `videoPreview(for:)` | Already exists, add `isEditing` branch |
| PanelView: `saveGifTrim(data:)` | PanelView: `saveVideoTrim(url:)` | File-based save, not blob update |

## Implementation

### 1. VideoTrimView — composition

`Sources/Views/VideoTrimView.swift`

Mirrors `GIFTrimView.swift` structure:

```swift
struct VideoTrimView: View {
    let url: URL
    let onSave: (URL) -> Void   // trimmed video temp file URL
    let onDiscard: () -> Void

    @State private var duration: Double = 0
    @State private var startTime: Double = 0      // seconds
    @State private var endTime: Double = 0        // seconds
    @State private var currentTime: Double = 0    // playhead position
    @State private var isLoaded = false
}
```

**Layout** (mirrors GIFTrimView):
- `VideoTrimPlayerView` (top — fills available space)
- `VideoTimelineScrubber` (bottom — fixed height)
- Duration label: `"Trimmed: 1:45 (was 2:34)"`

**Load**: On appear, read `AVAsset(url:).duration.seconds` → set `duration` and `endTime`.

**Save flow**:
1. Create `AVAssetExportSession` with `.passthrough` preset
2. Set `timeRange = CMTimeRange(start: CMTime(seconds: startTime), end: CMTime(seconds: endTime))`
3. Export to temp file in `NSTemporaryDirectory()`
4. Call `onSave(tempURL)` — PanelView handles the rest (hash, move, DB update)

**Discard**: Call `onDiscard()` — PanelView resets `isEditing`.

### 2. VideoTrimPlayerView — AVPlayer within trim range

`Sources/Views/VideoTrimPlayerView.swift`

Mirrors `GIFTrimPlayerView.swift` — `NSViewRepresentable` with Coordinator.

```swift
struct VideoTrimPlayerView: NSViewRepresentable {
    let url: URL
    let startTime: Double
    let endTime: Double
    @Binding var currentTime: Double
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
}
```

**Key behaviors**:
- Wraps `AVPlayerView` with `.controlsStyle = .none` (no transport controls — the scrubber IS the control)
- **Loop within range**: `addPeriodicTimeObserver` at 30Hz. When `currentTime >= endTime`, seek to `startTime`. Update `currentTime` binding for scrubber playhead sync.
- **Range change**: When `startTime`/`endTime` change (user drags handles), if current position is outside range, seek to `startTime`.
- **Keyboard**: Custom `NSView` subclass (like `GIFPlayerNSView`): Cmd+Return → `onSave?()`, Escape → `onDiscard?()`.
- **First responder**: Acquire focus on appear for keyboard handling.
- **Coordinator**: Holds the AVPlayer, time observer token, and NotificationCenter observer. Cleans up in `deinit`.

### 3. VideoTimelineScrubber — time-based drag handles

`Sources/Views/VideoTimelineScrubber.swift`

Mirrors `TimelineScrubber.swift` — `NSViewRepresentable` wrapping a native `NSView`.

```swift
struct VideoTimelineScrubber: NSViewRepresentable {
    let duration: Double          // total video duration in seconds
    @Binding var startTime: Double
    @Binding var endTime: Double
    let currentTime: Double       // playhead position (read-only)
}
```

**Layout** (same as TimelineScrubber):
- Background track (white 8% opacity)
- Range highlight (accent color 30% opacity)
- Playhead (2pt white line)
- Start handle (accent color, 14pt wide)
- End handle (accent color, 14pt wide)

**Mapping**: seconds ↔ pixels using `pixelsPerSecond = usableWidth / duration`. Same `mouseDown`/`mouseDragged`/`mouseUp` pattern.

**Minimum selection**: 0.5 seconds (prevent zero-length trim).

**Thumbnail strip** (enhancement over GIF scrubber):
- Generate 10-15 evenly spaced thumbnails via `AVAssetImageGenerator.generateCGImagesAsynchronously`
- Draw as background behind the track (small images, ~40px tall)
- Load async on appear, cache in Coordinator

**Label** (wrapper like `TimelineScrubberWithLabel`):
```swift
let trimmedDuration = endTime - startTime
Text(formatDuration(trimmedDuration) + " of " + formatDuration(duration))
```

### 4. PreviewPanel integration

`Sources/Views/PreviewPanel.swift`

Update `videoPreview(for:)` to branch on `isEditing`:

```swift
@ViewBuilder
private func videoPreview(for item: ClipboardRecord) -> some View {
    let url = ClipboardRecord.videoPath(for: item.contentHash)
    if isEditing, FileManager.default.fileExists(atPath: url.path) {
        VideoTrimView(
            url: url,
            onSave: { trimmedURL in onVideoSave?(trimmedURL) },
            onDiscard: { onDiscard?() }
        )
    } else if FileManager.default.fileExists(atPath: url.path) {
        InlineVideoPlayerView(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else { /* existing fallback */ }
}
```

Add `onVideoSave` callback to `PreviewPanel`:
```swift
var onVideoSave: ((URL) -> Void)?
```

### 5. PanelView integration

`Sources/Views/PanelView.swift`

**Right-arrow edit mode** — add video case (alongside existing text and GIF cases):
```swift
if item.kind == ClipboardRecord.kindVideo {
    let url = ClipboardRecord.videoPath(for: item.contentHash)
    if FileManager.default.fileExists(atPath: url.path) {
        enterEditMode()
        return .handled
    }
}
```

**Add callback** in PreviewPanel construction:
```swift
onVideoSave: { trimmedURL in saveVideoTrim(url: trimmedURL) }
```

**`saveVideoTrim(url:)`** — new method, mirrors `saveGifTrim(data:)`:

```swift
private func saveVideoTrim(url trimmedURL: URL) {
    guard isEditing else { return }
    isEditing = false
    let savedItemId = editingItemId
    editingItemId = nil
    isSearchFocused = true
    guard let itemId = savedItemId else { return }

    Task.detached {
        do {
            // 1. Compute hash of trimmed video (streaming)
            guard let hash = Self.streamingSHA256(of: trimmedURL) else {
                Log.error("PanelView: video trim hash failed")
                try? FileManager.default.removeItem(at: trimmedURL)
                return
            }

            // 2. Move trimmed file to videos directory
            let finalURL = ClipboardRecord.videoPath(for: hash)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: trimmedURL, to: finalURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)

            // 3. Extract new thumbnail at 0.5s
            let thumbnail = Self.extractThumbnail(from: finalURL)

            // 4. Get trimmed duration
            let asset = AVAsset(url: finalURL)
            let duration = try await asset.load(.duration).seconds
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            let formatted = String(format: "%d:%02d", minutes, seconds)

            // 5. Update DB: new hash, thumbnail, plainText, createdAt
            try await database.pool.write { db in
                // Delete old video file (get old hash first)
                if let oldRecord = try ClipboardRecord.fetchOne(db, key: itemId) {
                    let oldPath = ClipboardRecord.videoPath(for: oldRecord.contentHash)
                    if oldPath != finalURL {
                        try? FileManager.default.removeItem(at: oldPath)
                    }
                }

                // Dedup: delete any other record with same hash
                try db.execute(
                    sql: "DELETE FROM clipboardItem WHERE contentHash = ? AND id != ?",
                    arguments: [hash, itemId]
                )

                // Update record
                try db.execute(
                    sql: """
                        UPDATE clipboardItem
                        SET contentHash = ?, imageData = ?, plainText = ?, createdAt = ?
                        WHERE id = ?
                        """,
                    arguments: [hash, thumbnail, "Screen Recording (\(formatted))", Date(), itemId]
                )
            }
        } catch {
            Log.error("PanelView: saveVideoTrim failed: \(error)")
            try? FileManager.default.removeItem(at: trimmedURL)
        }
    }

    anchor = 0
    cursor = 0
}
```

The `streamingSHA256(of:)` and `extractThumbnail(from:)` helpers can be reused from `VideoCaptureService` — either make them `static` on a shared type, or duplicate the small helper (they're ~10 lines each).

## Files to create

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `Sources/Views/VideoTrimView.swift` | ~80 | Composition: player + scrubber + duration label |
| `Sources/Views/VideoTrimPlayerView.swift` | ~120 | AVPlayer within trim range, Cmd+Return/Escape |
| `Sources/Views/VideoTimelineScrubber.swift` | ~220 | Time-based scrubber with drag handles + thumbnail strip |

## Files to modify

| File | Change |
|------|--------|
| `PreviewPanel.swift` | Add `onVideoSave` callback, branch `videoPreview` on `isEditing` |
| `PanelView.swift` | Add video to right-arrow edit, add `onVideoSave` callback, add `saveVideoTrim(url:)` |

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Trim range < 0.5s | Scrubber enforces minimum 0.5s selection |
| Passthrough export snaps to keyframes | Accept ~2s precision (plan decision) |
| Video file deleted while trimming | `AVAssetExportSession` fails → discard, show error |
| Export fails (disk full) | Clean up temp file, show error via `Log.error` |
| Trim produces same hash as original | No file move needed, update timestamps only |
| User presses Escape during export | Discard — cancel export session, remove temp file |

## Acceptance Criteria

- [ ] Right arrow on video item enters trim mode
- [ ] Timeline scrubber with draggable start/end handles
- [ ] Thumbnail strip on the timeline
- [ ] Video plays within selected range, loops
- [ ] Duration label shows trimmed vs original duration
- [ ] Cmd+Return saves (lossless passthrough export)
- [ ] Escape discards
- [ ] Old video file deleted after successful trim
- [ ] Trimmed video gets new hash, thumbnail, duration in plainText
- [ ] Item moves to top of list after save
- [ ] File permissions 0600 on trimmed file

## References

- GIF trim pattern: `Sources/Views/GIFTrimView.swift`, `GIFTrimPlayerView.swift`, `TimelineScrubber.swift`
- GIF trim plan: `docs/plans/2026-02-17-feat-gif-trim-editing-plan.md`
- Video capture plan: `docs/plans/2026-03-29-feat-video-screen-capture-plan.md` (Phase 2 section)
- Crash-safe ordering: write new file → update DB → delete old file
