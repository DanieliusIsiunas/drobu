---
title: Video Screen Capture
type: feat
date: 2026-03-29
---

# Video Screen Capture

## Overview

Add video screen capture to Drobu — a separate hotkey (Ctrl+Shift+V) triggers region selection, records up to 5 minutes of screen as H.264 .mp4 via SCStream + AVAssetWriter, stores it in the clipboard history alongside text/images/GIFs, and pastes via file URL into Mattermost, Jira, Confluence, and Gmail. No audio in v1.

## Problem Statement

GIF capture works great for short demos (up to 15 seconds), but 1-5 minute recordings are needed for sharing use cases and demos. GIF can't scale to that duration (file size explodes, quality degrades). macOS has QuickTime Player, but the workflow is multi-step and cumbersome.

## Key Decisions

- **Trigger**: Separate hotkey (Ctrl+Shift+V), not shared with GIF
- **Storage**: Videos as files on disk at `~/Library/Application Support/ClipboardHistory/videos/{contentHash}.mp4`. Thumbnail JPEG in `imageData` column.
- **No schema migration**: File path derived from `kind == "video"` + `contentHash`
- **Encoding**: Real-time H.264 via AVAssetWriter during capture (not post-capture batch — 5 min at 15fps = 4500 frames, can't buffer in memory)
- **Paste**: File URL on pasteboard (same technique as GIF paste)
- **FPS**: 15 fps, `.nominal` resolution (1x logical)
- **Duration**: 5 minutes max (300s), hardcoded (configurable later if needed)
- **Bitrate**: 2 Mbps H.264 (~75MB for 5min at 1080p 15fps). Keyframe interval 2s.
- **Mutual exclusion**: Only one capture type (GIF or video) active at a time
- **No audio in v1** (mic voiceover planned as follow-up)

## Architecture

### New files

| File | Purpose |
|------|---------|
| `Sources/Services/VideoCaptureService.swift` | State machine, SCStream, AVAssetWriter real-time encoding |

### Existing files to modify

| File | Change |
|------|--------|
| `ClipboardRecord.swift` | Add `kindVideo`, `videosDirectory`, `videoPath(for:)` static helpers |
| `CaptureHotkeyDefaults.swift` | Add `VideoCaptureHotkeyDefaults` enum in same file |
| `AppDelegate.swift` | Add video service, hotkey, handler, completion callback, cleanup |
| `FloatingPanel.swift` | Add `kindVideo` paste case |
| `PreviewPanel.swift` | Add video preview (inline AVPlayer) + metadata bar |
| `ClipboardRowView.swift` | Add video row rendering (icon + duration) |
| `PanelView.swift` | Add video edit mode entry (Phase 2) |
| `SettingsView.swift` | Add "Capture Video Hotkey" row, fix "Delete All Data" |

## Implementation

### Phase 1: Record + Play + Paste

#### 1. ClipboardRecord extensions

`Sources/Models/ClipboardRecord.swift`

```swift
static let kindVideo = "video"

static var videosDirectory: URL {
    // ~/Library/Application Support/ClipboardHistory/videos/
}

static func videoPath(for contentHash: String) -> URL {
    videosDirectory.appendingPathComponent("\(contentHash).mp4")
}
```

Note: no `videoFilePath` computed property — use `ClipboardRecord.videoPath(for: record.contentHash)` directly at call sites (the `kind` check has already happened in every switch).

`plainText` stores `"Screen Recording (2:34)"` — duration baked in at capture time (distinct from GIF's `"Screen Capture"` for FTS5 searchability, and makes videos distinguishable in the list).

`imageData` stores thumbnail JPEG (first frame at **0.5 seconds**, not t=0 which shows region selection dismissing).

#### 2. VideoCaptureHotkeyDefaults

Add to existing `Sources/Models/CaptureHotkeyDefaults.swift`:

```swift
enum VideoCaptureHotkeyDefaults {
    static let key = "videoCaptureHotkey"
    // Same save/load pattern as CaptureHotkeyDefaults
    // Notification: .videoCaptureHotkeyDidChange
    // Default: Ctrl+Shift+V
}
```

#### 3. VideoCaptureService — the core

`Sources/Services/VideoCaptureService.swift`

State machine: `idle → selecting → recording → finalizing → idle`

Same pattern as `ScreenCaptureService` — reuses `RegionSelectionPanel`, `RecordingIndicatorWindow`, and permission checks (already separate components). The state machine is small (~10 lines of enum + transitions).

**Key architectural difference from GIF capture:**

GIF capture buffers all frames in memory as compressed JPEGs, then batch-encodes to GIF after recording stops. Video capture writes H.264 frames to disk in real-time during recording via AVAssetWriter. This is why a separate service is justified — the encoding pipeline is fundamentally different.

**Recording flow:**

1. `startRegionSelection()` — creates `RegionSelectionPanel` (reuse existing component)
2. `beginRecording(rect:screen:)`:
   - Create temp .mp4 file path in `NSTemporaryDirectory()` (`UUID().uuidString + ".mp4"`) — **not in videos directory**, to prevent orphan cleanup from deleting it mid-recording
   - Ensure videos directory exists (`FileManager.createDirectory(at:withIntermediateDirectories:attributes:)` with `[.posixPermissions: 0o700]`)
   - Initialize `AVAssetWriter(outputURL: tempPath, fileType: .mp4)`
   - Add `AVAssetWriterInput` with `AVVideoCodecType.h264`, matching dimensions from selection rect, and explicit settings:
     - `AVVideoAverageBitRateKey`: 2_000_000 (2 Mbps — good for screen content with low motion)
     - `AVVideoMaxKeyFrameIntervalKey`: 30 (2s at 15fps — affects trim precision in Phase 2)
     - `AVVideoProfileLevelKey`: `AVVideoProfileLevelH264HighAutoLevel`
   - **Set `expectsMediaDataInRealTime = true`** on the input (critical for real-time capture)
   - Create `AVAssetWriterInputPixelBufferAdaptor` for BGRA pixel buffer input
   - Start `AVAssetWriter`, then start `SCStream`
3. `VideoFrameOutput` (inner class, implements `SCStreamOutput`):
   - Receives `CMSampleBuffer` on background queue
   - **Check `writerInput.isReadyForMoreMediaData`** — if false, drop the frame (don't block SCStream queue)
   - **Check `writer.status != .failed`** — if failed, signal service to stop
   - Append pixel buffer via adaptor with presentation time
   - **No Log calls** in this callback (hot path, per CLAUDE.md rules)
4. `stopRecording()`:
   - Invalidate auto-stop timer (5 min / 300s)
   - `await stream.stopCapture()` — **must complete before touching writer** (ensures no more callbacks)
   - Dismiss recording indicator
   - `writer.finishWriting(completionHandler:)` — finalize the .mp4
5. `finalizeRecording()`:
   - **Compute SHA256 of the .mp4 file on a background queue** using streaming hash (1MB chunk reads via `FileHandle` + `SHA256.update(data:)`) to avoid loading the entire file into memory. ~200-400ms on Apple Silicon, ~600ms on Intel. Must not block main thread.
   - Move temp file from `NSTemporaryDirectory()` to `videos/{hash}.mp4` (delete destination first if exists). Set file permissions to `0600`.
   - Extract thumbnail: `AVAssetImageGenerator` at `CMTime(seconds: 0.5)` → JPEG data
   - Fire `onCaptureComplete?(finalURL, thumbnailJPEG)`

**Cancel flow:**

- **Escape during recording**: Install `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` when recording starts. Escape → `cancelRecording()` (stop stream, cancel writer, delete temp file, return to idle). Remove monitor when recording ends.
- **Hotkey during recording**: `stopRecording()` (finalize and save)
- **Hotkey during selecting**: Cancel selection (same as GIF)

**Error handling:**

- AVAssetWriter init failure → `onCaptureError`, return to idle
- `writer.status == .failed` during recording → stop stream, delete temp file, show error
- Disk full → AVAssetWriter fails, same as above
- Rename failure → delete destination if exists, retry; if still fails, report error + clean up temp

**Callbacks** (same pattern as ScreenCaptureService):
```swift
var onCaptureComplete: ((URL, Data, TimeInterval) -> Void)?  // (videoFileURL, thumbnailJPEG, duration)
var onCaptureError: ((String) -> Void)?
var onStateChange: ((State) -> Void)?
```

#### 4. AppDelegate integration

`Sources/App/AppDelegate.swift`

```swift
private var videoCaptureService: VideoCaptureService?
private var videoCaptureHotKey: HotKey?
private var videoCaptureHotkeyObserver: Any?
```

- `registerVideoCaptureHotkey()` — same pattern as `registerCaptureHotkey()`
- `handleVideoCaptureHotkey()`:
  - **Mutual exclusion**: `guard captureService?.state == .idle else { return }` (GIF not busy)
  - Dispatch on video service state: `.idle` → start, `.selecting` → cancel, `.recording` → stop, `.finalizing` → ignore
- `handleVideoCaptureComplete(videoURL:thumbnail:duration:)`:
  - Format duration as `"M:SS"` (e.g., `"2:34"`)
  - Create `ClipboardRecord(kind: .kindVideo, plainText: "Screen Recording (\(formatted))", imageData: thumbnail, sourceApp: "Screen Capture", sourceBundleId: Bundle.main.bundleIdentifier, contentHash: hash, ...)`
  - Save to DB via `Task.detached { pool.write { ClipboardRecord.upsert() } }`
  - `monitor.suppressNextChange()`
  - Write file URL to pasteboard: `pasteboard.writeObjects([videoURL as NSURL])`

**Mutual exclusion** — add to existing `handleCaptureHotkey()`:
```swift
guard videoCaptureService?.state == .idle else { return }  // Video not busy
```

**Panel toggle guard** — add to existing `togglePanel()`:
```swift
guard videoCaptureService?.state == .idle else { return }  // Block panel during video recording
```

**Cleanup** — in `runCleanup()`, after the existing `ClipboardRecord.cleanup()` call:
```swift
// Orphan cleanup: remove video files with no matching DB record
let knownHashes = try Set(db.read { try ClipboardRecord.allVideoHashes(in: $0) })
if let files = try? FileManager.default.contentsOfDirectory(at: ClipboardRecord.videosDirectory, ...) {
    for file in files where file.pathExtension == "mp4" {
        let hash = file.deletingPathExtension().lastPathComponent
        if !knownHashes.contains(hash) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
```

Inline the video hash query directly (no dedicated helper method — only one caller):
```swift
let knownHashes = try Set(String.fetchAll(db, sql: "SELECT contentHash FROM clipboardItem WHERE kind = 'video'"))
```

This single orphan-scan mechanism handles all cases: age/count cleanup, manual delete, crash recovery.

**Delete All Data** — also purge videos directory:
```swift
try? FileManager.default.removeItem(at: ClipboardRecord.videosDirectory)
```

**App termination during recording** — in `applicationWillTerminate`:
Do NOT attempt synchronous finalization (DispatchSemaphore + @MainActor = deadlock). Simply accept the orphan — the temp file is in `NSTemporaryDirectory()` (OS cleans it on reboot) and orphan scan catches any files that made it to the videos directory.

#### 5. FloatingPanel — video paste

`Sources/Views/FloatingPanel.swift`

Add to `pasteItem(_:)`:
```swift
case ClipboardRecord.kindVideo:
    let url = ClipboardRecord.videoPath(for: record.contentHash)
    if FileManager.default.fileExists(atPath: url.path) {
        pasteboard.writeObjects([url as NSURL])
    }
```

Add `.video(URL)` case to `PasteOperation` enum for multi-select paste. In `executePasteSequence`, treat `.video` like `.image` for delay timing (500ms between operations — receiving apps need time to process file references).

Uses the stable file path (not a temp copy). Trade-off: if user deletes the record then another app reads the pasteboard lazily, the URL is broken. Same risk window as any clipboard content — acceptable.

#### 6. ClipboardRowView — video row

`Sources/Views/ClipboardRowView.swift`

New case in `contentView` — text-only label, matching the GIF/image row pattern (no thumbnail decode in scroll path):
```swift
case ClipboardRecord.kindVideo:
    Text(item.plainText ?? "Screen Recording")
        .font(.system(size: 15))
        .foregroundStyle(.primary)
        .lineLimit(1)
```

Icon: `"video.fill"` in `appIcon` switch.

`plainText` stores `"Screen Recording (2:34)"` — duration baked in at capture time (known from the recording timer). Makes videos distinguishable in the list. Full metadata (resolution, file size, thumbnail) in the preview panel only.

#### 7. PreviewPanel — inline video player + metadata

`Sources/Views/PreviewPanel.swift`

Add `videoPreview(for:)` branch in `previewContent`:

- Inline `NSViewRepresentable` wrapping `AVPlayerView` (~20 lines, private struct in PreviewPanel)
- Takes video file URL (via `ClipboardRecord.videoPath(for: item.contentHash)`)
- `controlsStyle = .inline` (play/pause + scrub bar)
- Loop via `NSNotification.Name.AVPlayerItemDidPlayToEndTime`
- No volume controls (no audio in v1)
- **Debounce AVPlayer creation** (~200-300ms): show the thumbnail JPEG (from `imageData`) immediately on selection, then create AVPlayer only after the cursor has been stable for 200ms. Prevents rapid-fire AVPlayer allocation when arrowing through the list. Cancel pending creation on cursor change.
- **Lifecycle caution** (per `.claude/rules/swiftui-macos-gotchas.md`): `onAppear`/`onDisappear` don't fire reliably in NSHostingView. Pause and release the AVPlayer in `updateNSView` when the URL changes (item selection changes) and in `dismantleNSView` (panel closes). Prevents leaked players and phantom audio once audio is added in v2.

Metadata bar for video:
- Resolution + duration from `AVAsset(url:)` properties
- File size from `FileManager.attributesOfItem`
- Creation date from `item.createdAt`

#### 8. SettingsView

`Sources/Views/SettingsView.swift`

Add state property alongside the existing ones:
```swift
@State private var videoCaptureHotkeyCombo: KeyCombo? = VideoCaptureHotkeyDefaults.load()
```

Add row below the "Capture GIF Hotkey" row, inside `Section("General")`:
```swift
HStack {
    Text("Capture Video Hotkey")
    Spacer()
    HotkeyRecorderView(keyCombo: $videoCaptureHotkeyCombo, saveAction: VideoCaptureHotkeyDefaults.save)
        .frame(width: 160, height: 24)
}
```

Fix `confirmAndDeleteAll()` to also remove the videos directory.

#### 9. PanelView — delete cleanup

In `deleteSelected()`, before the DB delete, check if any items are videos and delete their files:
```swift
for item in toDelete where item.kind == ClipboardRecord.kindVideo {
    try? FileManager.default.removeItem(at: ClipboardRecord.videoPath(for: item.contentHash))
}
```

### Phase 2: Video Trim (later)

#### VideoTrimView

`Sources/Views/VideoTrimView.swift`

- Timeline scrubber with start/end handles
- Thumbnail strip via `AVAssetImageGenerator` (10-20 evenly spaced)
- `AVPlayerView` constrained to trim range for preview
- Duration display: "Trimmed: 1:45 (was 2:34)"
- Cmd+Return → save, Escape → discard

#### Trim save flow (crash-safe ordering)

1. Export trimmed video via `AVAssetExportSession` with `.passthrough` preset (lossless, fast, keyframe-aligned) to a new temp file
2. Compute new content hash
3. **Write new file to final path** (by hash)
4. **Update DB record** in single transaction (new hash, new thumbnail, new createdAt)
5. **Delete old file** if hash changed

This ordering ensures a crash at any point leaves either the old version intact or the new version fully committed. Orphan cleanup handles any leftover temp files.

Trade-off: `.passthrough` snaps to keyframe boundaries (~2s intervals). Acceptable for screen capture.

#### PanelView edit mode

Right arrow on video item → `isEditing = true` → show `VideoTrimView`.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Disk full during recording | AVAssetWriter fails → stop stream, delete temp file, show alert |
| App quit during recording | Accept orphan — temp file is in NSTemporaryDirectory (OS cleans on reboot) |
| App crash during recording | Same — temp file in NSTemporaryDirectory, orphan scan catches videos dir |
| Escape during recording | Cancel: stop stream, cancel writer, delete temp file |
| GIF hotkey during video recording | Ignored (mutual exclusion) |
| Video hotkey during GIF recording | Ignored (mutual exclusion) |
| Panel hotkey during recording | Ignored (matches GIF behavior) |
| Permission denied | Show alert with System Settings link (reuse existing) |
| Delete video from history | Delete .mp4 file, then DB record |
| Cleanup deletes old videos | Orphan scan after DB cleanup removes unreferenced files |
| Delete All Data | Purge videos directory + DB |
| Very short recording (<1s) | Save normally, user can delete |
| Video file missing on paste | `fileExists` check → skip paste, item stays in history |

## Acceptance Criteria

### Phase 1
- [ ] Ctrl+Shift+V triggers region selection → recording → save
- [ ] Recording indicator shows elapsed time
- [ ] Auto-stops at 5 minutes
- [ ] Escape cancels recording (discards)
- [ ] Hotkey stops recording (saves)
- [ ] Video appears in history with thumbnail + "Screen Recording"
- [ ] Preview panel shows inline video player with controls
- [ ] Return pastes .mp4 file URL → works in Mattermost and Jira
- [ ] Delete removes both DB record and .mp4 file
- [ ] Cleanup + orphan scan removes unreferenced video files
- [ ] Delete All Data purges videos directory
- [ ] Settings shows configurable video hotkey
- [ ] Mutual exclusion between GIF and video capture
- [ ] Content hash computed off main thread
- [ ] AVAssetWriter uses `expectsMediaDataInRealTime = true`

### Phase 2
- [ ] Right arrow on video enters trim mode
- [ ] Timeline scrubber with thumbnail strip
- [ ] Cmd+Return saves trimmed video (lossless passthrough)
- [ ] Escape discards trim
- [ ] Crash-safe trim ordering: write → update DB → delete old

## References

- GIF capture: `Sources/Services/ScreenCaptureService.swift`
- GIF capture plan: `docs/plans/2026-02-18-feat-gif-screen-capture-plan.md`
- GIF trim plan: `docs/plans/2026-02-17-feat-gif-trim-editing-plan.md`
- Hotkey pattern: `Sources/Models/CaptureHotkeyDefaults.swift`
- Recording indicator: `Sources/Views/RecordingIndicatorWindow.swift`
- Region selection: `Sources/Views/RegionSelectionPanel.swift`
- SwiftUI macOS gotchas: `.claude/rules/swiftui-macos-gotchas.md`
