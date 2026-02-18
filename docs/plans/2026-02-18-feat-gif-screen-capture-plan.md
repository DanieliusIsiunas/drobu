---
title: "feat: Add GIF screen capture"
type: feat
date: 2026-02-18
brainstorm: docs/brainstorms/2026-02-18-gif-screen-capture-brainstorm.md
---

# feat: Add GIF Screen Capture (Phase 3)

## Overview

Add built-in screen region recording that outputs GIFs directly into clipboard history. Press a global hotkey, drag a region, recording starts immediately. Press the hotkey again to stop — the GIF is encoded, saved to the database, and written to the pasteboard ready to paste. No app switching, no file management, no preview step.

This is Phase 3 of the GIF roadmap (Preview → Trim → **Screen Capture**).

## Problem Statement / Motivation

Creating GIFs for bug reports, Slack demos, and documentation requires a multi-app workflow: record with Gifox/Kap → find the file → copy → paste. The clipboard is already the hub for text, images, and GIFs — screen capture should flow through it too. Capture → trim (Phase 2) → paste, all in one tool.

## Proposed Solution

A `ScreenCaptureService` that uses ScreenCaptureKit's `SCStream` to capture frames from a user-selected screen region, encodes them via the existing `GIFFrameEngine`, and saves the result to the clipboard history database + pasteboard. Triggered by a dedicated global hotkey, separate from the panel toggle.

## Technical Approach

### Capture State Machine

The capture feature has five distinct states with strict transitions:

```
                 ┌──────────────────────────────────┐
                 │                                   │
                 ▼                                   │
    ┌────────┐  hotkey   ┌───────────┐  mouse-up  ┌───────────┐
    │  Idle  │ ────────► │ Selecting │ ──────────► │ Recording │
    └────────┘           └───────────┘             └───────────┘
        ▲                    │                      │         │
        │                    │ Escape               │ hotkey  │ 15s timeout
        │                    ▼                      │         │
        │               (cancel, dismiss)           ▼         ▼
        │                    │                 ┌──────────┐
        │                    │                 │ Encoding │
        │                    │                 └──────────┘
        │                    │                      │
        └────────────────────┴──────────────────────┘
                        → back to Idle
```

**State guards:**
- Hotkey press in **Idle** → enter Selecting
- Hotkey press in **Selecting** → cancel, return to Idle
- Hotkey press in **Recording** → stop, enter Encoding
- Hotkey press in **Encoding** → ignored (encoding in progress)
- Escape in **Selecting** → cancel, return to Idle
- Escape in **Recording** → cancel and **discard**, return to Idle (no save)
- 15s timeout in **Recording** → stop, enter Encoding (same as hotkey)
- Encoding complete → return to Idle

**Panel interaction:** Starting capture (entering Selecting) closes the clipboard panel if open. Panel hotkey is ignored while capture state is not Idle.

### Change 1: ScreenCaptureService

**New file:** `Sources/Services/ScreenCaptureService.swift`

Core service managing the SCStream lifecycle. `@MainActor` isolated, following the `ClipboardMonitor` pattern.

```swift
@MainActor
final class ScreenCaptureService {
    enum State { case idle, selecting, recording, encoding }

    private(set) var state: State = .idle
    private var stream: SCStream?
    private var frameOutput: FrameCaptureOutput?
    private var autoStopTimer: Timer?

    // Callbacks
    var onCaptureComplete: ((Data) -> Void)?  // GIF data
    var onCaptureError: ((Error) -> Void)?
    var onStateChange: ((State) -> Void)?
}
```

**FrameCaptureOutput** (nested class or separate file): Implements `SCStreamOutput` protocol. Receives `CMSampleBuffer` frames on a serial `DispatchQueue`, filters for `.complete` status, converts to `CGImage` via `CIContext`, and appends to a thread-safe `[CGImage]` array.

**Key implementation details:**

- `CIContext` created once and reused (GPU-backed, expensive to allocate)
- Pixel format: `kCVPixelFormatType_32BGRA` (required for CGImage conversion, not the default YCbCr)
- Frame status filtering: only process `.complete` frames, skip `.idle`/`.blank`/`.suspended`
- Thread safety: `NSLock` protecting the frames array (SCStreamOutput callbacks arrive on a background DispatchQueue)
- `captureResolution = .nominal` for 1x output (not Retina 2x)

**SCStream configuration:**

| Property | Value | Rationale |
|----------|-------|-----------|
| `sourceRect` | User-selected region | Crops capture to the dragged rectangle |
| `width` / `height` | Region size in points | 1x resolution output |
| `minimumFrameInterval` | `CMTime(value: 1, timescale: 10)` | 10 FPS |
| `queueDepth` | 5 | Prevents dropped frames at 10fps |
| `showsCursor` | `true` | Include mouse cursor in capture |
| `pixelFormat` | `kCVPixelFormatType_32BGRA` | Required for CGImage conversion |
| `captureResolution` | `.nominal` | 1x scale (point-based, not Retina) |
| `capturesAudio` | `false` | GIFs have no audio |
| `scalesToFit` | `true` | Scale sourceRect content to output dimensions |

**SCContentFilter setup:**
- Use `SCContentFilter(display:excludingApplications:exceptingWindows:)` with empty arrays (capture everything on the display)
- The `sourceRect` on the configuration handles region cropping — no need for window or app filtering
- Display determined from `NSScreen` containing the mouse cursor at capture start

**Memory management strategy:**

At 10fps for 15s with ~8MB per 1920x1080 CGImage frame, a worst-case capture buffers ~1.2GB. Mitigation:

1. **Store compressed JPEG data instead of raw CGImages.** After each frame arrives, compress to JPEG (quality 0.8) and store `Data` instead of `CGImage`. A 1920x1080 JPEG at quality 0.8 is ~200KB vs ~8MB raw. 150 frames × 200KB = ~30MB peak memory.
2. **Convert JPEG back to CGImage only during encoding.** `GIFFrameEngine.encodeFrames()` needs CGImages, so decompress each frame just before passing to `CGImageDestination`. This happens sequentially during encoding, so only one decompressed frame is in memory at a time.
3. **Release the compressed buffer after encoding.** The `[Data]` array is freed as soon as encoding produces the final GIF `Data`.

This approach trades CPU (JPEG compress/decompress) for memory (30MB vs 1.2GB). At 10fps, JPEG compression on the GPU (via `CIContext`) is fast enough.

```swift
// In FrameCaptureOutput.stream(_:didOutputSampleBuffer:of:):
let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

// Compress to JPEG Data immediately, release CGImage
let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
guard let tiffData = nsImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
else { return }

lock.lock()
compressedFrames.append(jpegData)
lock.unlock()
// cgImage goes out of scope and is released
```

### Change 2: RegionSelectionPanel

**New file:** `Sources/Views/RegionSelectionPanel.swift`

A borderless, full-screen `NSPanel` for drag-to-select region capture. Follows the `FloatingPanel` init pattern.

**Panel properties:**
- `styleMask: [.borderless, .nonactivatingPanel]`
- `level: .screenSaver` (above everything including other floating panels)
- `backgroundColor: NSColor.black.withAlphaComponent(0.2)` (semi-transparent dim overlay)
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`
- Sized to cover the screen containing the mouse cursor (`NSScreen` from `NSEvent.mouseLocation`)
- `ignoresMouseEvents = false` (receives click/drag events)
- `canBecomeKey = true` (receives keyboard events for Escape)

**Mouse handling (NSView subclass inside the panel):**
- `mouseDown` → record start point, begin rubber-band selection
- `mouseDragged` → update selection rectangle, draw selection box with dimensions label
- `mouseUp` → finalize selection, callback with `CGRect`, dismiss panel

**Visual elements during selection:**
- Crosshair cursor (`NSCursor.crosshair`)
- Selection rectangle with thin white border (2px) and clear interior
- Dimension label centered below the selection: `"640 × 480"` (white text, dark background pill)
- Area outside selection stays dimmed

**Escape handling:**
- `keyDown` with `event.keyCode == 53` (Escape) → cancel, dismiss panel, no callback

**Minimum region size:** 20×20 points. If the user drags less than this, treat as a cancel (dismiss, no callback).

**Coordinate mapping:** The panel's view uses AppKit coordinates (origin bottom-left). `sourceRect` for SCStream uses Core Graphics coordinates (origin top-left on the display). The conversion:

```swift
// Convert AppKit view coordinates to CG display coordinates for sourceRect
let screen = panel.screen ?? NSScreen.main!
let screenFrame = screen.frame
let cgRect = CGRect(
    x: selectionRect.origin.x,
    y: screenFrame.height - selectionRect.origin.y - selectionRect.height,
    width: selectionRect.width,
    height: selectionRect.height
)
```

### Change 3: Recording Indicator

**New file:** `Sources/Views/RecordingIndicatorWindow.swift`

A small floating HUD shown during recording. Positioned just above the captured region (or below if the region is at the top of the screen). Does NOT overlap the capture region.

**Design:**
- Borderless `NSWindow` (not NSPanel — does not need to be key)
- `level: .screenSaver` (same as selection overlay)
- `ignoresMouseEvents = true` (click-through)
- Content: red recording dot (pulsing) + elapsed time counter + `"⌃⇧G to stop"` label
- Size: ~200×30px, rounded corners, dark semi-transparent background
- Auto-updates every 0.1s (timer)
- Positioned outside the sourceRect so it's not captured in the GIF

**Positioning logic:**
```
If region.minY > 40:  place above region (region.minY - 40)
Else:                  place below region (region.maxY + 8)
```

### Change 4: CaptureHotkeyDefaults

**New file:** `Sources/Models/CaptureHotkeyDefaults.swift`

Clone of `HotkeyDefaults` pattern from `HotkeyRecorderView.swift:12-31`:

```swift
extension Notification.Name {
    static let captureHotkeyDidChange = Notification.Name("captureHotkeyDidChange")
}

enum CaptureHotkeyDefaults {
    static let key = "captureHotkey"

    static func save(_ combo: KeyCombo?) {
        if let combo {
            UserDefaults.standard.set(combo.dictionary, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .captureHotkeyDidChange, object: nil)
    }

    static func load() -> KeyCombo {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let combo = KeyCombo(dictionary: dict) else {
            return KeyCombo(key: .g, modifiers: [.control, .shift])  // Ctrl+Shift+G
        }
        return combo
    }
}
```

**Default hotkey: Ctrl+Shift+G.**
- Avoids conflict with panel toggle (Cmd+Shift+V)
- Avoids conflict with macOS screenshot (Cmd+Shift+3/4/5)
- "G" for GIF — memorable mnemonic
- Uses Ctrl modifier (not Cmd) to clearly separate from the Cmd-based panel hotkey

### Change 5: Parameterize HotkeyRecorderView

**File:** `Sources/Views/HotkeyRecorderView.swift`

The current `HotkeyRecorderNSView` hard-codes `HotkeyDefaults.save(combo)` at line 137. To support a second hotkey recorder, parameterize the save action:

Add a `saveAction` closure to `HotkeyRecorderNSView`:

```swift
// Current (line 137):
HotkeyDefaults.save(combo)

// Change to:
var saveAction: (KeyCombo?) -> Void = { HotkeyDefaults.save($0) }
// ...
saveAction(combo)
```

Update `HotkeyRecorderView` (the SwiftUI wrapper) to accept an optional `saveAction` parameter, defaulting to `HotkeyDefaults.save` for backward compatibility. When used for the capture hotkey, pass `CaptureHotkeyDefaults.save`.

### Change 6: Update AppDelegate

**File:** `Sources/App/AppDelegate.swift`

Add second hotkey registration alongside the panel hotkey:

```swift
// New properties (alongside existing hotKey/hotkeyObserver at lines 10-12):
private var captureHotKey: HotKey?
private var captureHotkeyObserver: Any?
private var captureService: ScreenCaptureService?

// In applicationDidFinishLaunching (alongside line 32):
captureService = ScreenCaptureService()
captureService?.onCaptureComplete = { [weak self] gifData in
    self?.handleCaptureComplete(gifData)
}
registerCaptureHotkey(CaptureHotkeyDefaults.load())

// New observer (alongside lines 35-43):
captureHotkeyObserver = NotificationCenter.default.addObserver(
    forName: .captureHotkeyDidChange, ...
) { ... registerCaptureHotkey(CaptureHotkeyDefaults.load()) }

// New method (alongside registerHotkey at lines 112-118):
private func registerCaptureHotkey(_ combo: KeyCombo) {
    captureHotKey = nil
    captureHotKey = HotKey(keyCombo: combo)
    captureHotKey?.keyDownHandler = { [weak self] in
        self?.handleCaptureHotkey()
    }
}
```

**`handleCaptureHotkey()` — state machine driver:**

```swift
private func handleCaptureHotkey() {
    guard let service = captureService else { return }
    switch service.state {
    case .idle:
        // Close panel if open, then start region selection
        if panel?.isVisible == true { togglePanel() }
        service.startRegionSelection()
    case .selecting:
        // Cancel selection
        service.cancelSelection()
    case .recording:
        // Stop recording → enters encoding
        service.stopRecording()
    case .encoding:
        // Ignore — encoding in progress
        break
    }
}
```

**`handleCaptureComplete(_ gifData: Data)` — save and paste:**

```swift
private func handleCaptureComplete(_ gifData: Data) {
    let hash = gifData.sha256String
    let record = ClipboardRecord(
        kind: ClipboardRecord.kindGif,
        plainText: "Screen Capture",
        imageData: gifData,
        sourceApp: "Screen Capture",
        sourceBundleId: Bundle.main.bundleIdentifier,
        contentHash: hash,
        createdAt: Date()
    )

    // Save to database
    let db = database
    Task.detached {
        try? await db.pool.write { dbConn in
            try ClipboardRecord.upsert(record, in: dbConn)
        }
    }

    // Write to pasteboard (GIF + PNG fallback)
    monitor?.suppressNextChange()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(gifData, forType: .gif)
    if let nsImage = NSImage(data: gifData),
       let tiffData = nsImage.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        pasteboard.setData(pngData, forType: .png)
    }
}
```

**Permission check** (new method, follows `checkAccessibilityOnLaunch` pattern at lines 88-108):

```swift
func checkScreenCapturePermission() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }

    CGRequestScreenCaptureAccess()

    let alert = NSAlert()
    alert.messageText = "Screen Recording Permission Required"
    alert.informativeText = """
        ClipboardHistory needs Screen Recording permission to capture GIFs. \
        Click 'Open System Settings' and toggle on ClipboardHistory.
        """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Cancel")

    if alert.runModal() == .alertFirstButtonReturn {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    return false
}
```

Called on first capture attempt (not on launch — don't ask for permission until the user actually tries to capture).

**Panel hotkey guard:** In `togglePanel()`, add an early return if capture is active:

```swift
private func togglePanel() {
    if captureService?.state != .idle { return }  // Ignore while capturing
    // ... existing panel toggle logic
}
```

### Change 7: Update SettingsView

**File:** `Sources/Views/SettingsView.swift`

Add capture hotkey recorder in the "General" section, after the existing panel hotkey row (line 19):

```swift
@State private var captureHotkeyCombo: KeyCombo? = CaptureHotkeyDefaults.load()

// Inside Section("General"), after the panel hotkey HStack:
HStack {
    Text("Capture Hotkey")
    Spacer()
    HotkeyRecorderView(keyCombo: $captureHotkeyCombo, saveAction: CaptureHotkeyDefaults.save)
        .frame(width: 160, height: 24)
}
```

### Change 8: Update Info.plist

**File:** `Sources/Info.plist`

Add screen recording usage description:

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>ClipboardHistory needs screen recording access to capture GIF screen recordings.</string>
```

### Change 9: Extend GIFFrameEngine

**File:** `Sources/Services/GIFFrameEngine.swift`

Add a method to encode frames from compressed JPEG data (for the memory-efficient capture pipeline):

```swift
/// Encode GIF from compressed frame data (JPEG).
/// Decompresses one frame at a time to minimize peak memory.
static func encodeFromCompressedFrames(_ compressedFrames: [Data], delay: Double) -> Data? {
    guard !compressedFrames.isEmpty else { return nil }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.gif.identifier as CFString,
        compressedFrames.count,
        nil
    ) else { return nil }

    // File-level: infinite loop
    let fileProperties: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFLoopCount as String: 0
        ]
    ]
    CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

    // Add each frame: decompress JPEG → CGImage → add to destination
    let frameProperties: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: delay
        ]
    ]
    for jpegData in compressedFrames {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { continue }
        CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        // cgImage released at end of loop iteration
    }

    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
```

### 20MB Overflow Handling

If the encoded GIF exceeds 20MB:

1. **First attempt:** Encode at full quality (as above)
2. **If > 20MB:** Re-encode skipping every other frame (effectively 5fps) — halves size
3. **If still > 20MB:** Show HUD error "Recording too large — try a smaller region or shorter duration" and discard

This is simple, requires no new UI, and handles the common case (large region + long duration).

```swift
func encodeWithSizeLimit(_ frames: [Data], delay: Double, maxBytes: Int = 20_000_000) -> Data? {
    // Full quality attempt
    if let data = GIFFrameEngine.encodeFromCompressedFrames(frames, delay: delay),
       data.count <= maxBytes {
        return data
    }

    // Half frame rate attempt
    let everyOther = frames.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    if let data = GIFFrameEngine.encodeFromCompressedFrames(everyOther, delay: delay * 2),
       data.count <= maxBytes {
        return data
    }

    return nil  // Too large even at reduced quality
}
```

## Data Flow

```
Ctrl+Shift+G (Idle)
    → Close panel if open
    → Check screen recording permission (first time: alert + system dialog)
    → Show RegionSelectionPanel (full-screen dim overlay)
    → User drags rectangle (crosshair cursor, dimension label)
    → Mouse up: dismiss overlay, start SCStream with sourceRect
    → Show RecordingIndicatorWindow (red dot + timer + "⌃⇧G to stop")
    → FrameCaptureOutput receives CMSampleBuffers on background queue
    → Each frame: validate .complete → CIContext → CGImage → JPEG compress → append to [Data]

Ctrl+Shift+G (Recording) OR 15s timeout
    → Stop SCStream
    → Dismiss RecordingIndicatorWindow
    → Show "Creating GIF..." HUD
    → Encode: GIFFrameEngine.encodeFromCompressedFrames([Data], delay: 0.1)
    → Size check: if > 20MB, re-encode at 5fps; if still > 20MB, show error
    → Save to DB: ClipboardRecord.upsert(kind: "gif", imageData: gifData)
    → Write to pasteboard: GIF + PNG fallback
    → Suppress ClipboardMonitor
    → Dismiss HUD, return to Idle
    → User can Cmd+V immediately
```

## Acceptance Criteria

### Functional Requirements

- [ ] Pressing Ctrl+Shift+G shows a full-screen dim overlay for region selection
- [ ] Dragging draws a selection rectangle with dimension label (e.g., "640 × 480")
- [ ] Releasing the mouse starts recording the selected region at 10fps
- [ ] A recording indicator (red dot + timer) appears outside the captured region
- [ ] Pressing Ctrl+Shift+G again stops recording and encodes the GIF
- [ ] Recording auto-stops at 15 seconds
- [ ] Pressing Escape during selection cancels without recording
- [ ] Pressing Escape during recording discards the capture (no save)
- [ ] Encoded GIF is saved to database as `kind = "gif"`
- [ ] Encoded GIF is written to pasteboard (GIF + PNG fallback)
- [ ] ClipboardMonitor does not re-record the pasteboard write
- [ ] Captured GIF appears in the clipboard history panel
- [ ] Captured GIF can be trimmed using the Phase 2 editor (right arrow → trim mode)
- [ ] Captured GIF can be pasted from the panel (same as any GIF)
- [ ] GIFs over 20MB are re-encoded at reduced frame rate; if still too large, show error
- [ ] Capture hotkey is configurable in Settings (separate from panel hotkey)
- [ ] Default capture hotkey is Ctrl+Shift+G
- [ ] Screen recording permission is requested on first capture attempt
- [ ] Permission alert directs user to System Settings > Screen Recording

### Non-Functional Requirements

- [ ] Peak memory during 15s capture stays under 100MB (JPEG compression strategy)
- [ ] Encoding 150 frames completes in under 3 seconds
- [ ] No dropped frames at 10fps (queueDepth = 5)
- [ ] Capture resolution is 1x (point-based, not Retina) for manageable file sizes
- [ ] Swift 6 strict concurrency: no sendability warnings

### Integration Requirements

- [ ] Panel hotkey is ignored while capture is active
- [ ] Starting capture closes the panel if it's open
- [ ] Hotkey press during encoding is ignored (no double-fire)
- [ ] Minimum region size enforced: 20×20 points
- [ ] Mouse cursor is visible in captured GIF frames
- [ ] `sourceApp` set to "Screen Capture" for captured GIFs
- [ ] Captured GIFs are searchable by "Screen Capture" in the panel
- [ ] Existing text, image, and GIF clipboard functionality unaffected

## Dependencies & Risks

**Low risk:**
- `GIFFrameEngine.encodeFrames()` is proven from Phase 2
- Global hotkey pattern is identical to existing panel hotkey
- `ClipboardRecord.upsert()` and dual-format paste are proven
- `NSPanel` subclass pattern follows `FloatingPanel`

**Medium risk:**
- **ScreenCaptureKit is new to this codebase.** Mitigated: well-documented Apple framework, macOS 14+ means full API available, research covers the key patterns.
- **Permission persistence across builds.** The `ClipboardHistoryDev` certificate preserves Accessibility permissions; Screen Recording TCC entries may behave differently. Mitigated: permission check on first capture, not on launch.
- **Memory management.** JPEG compression strategy reduces peak from ~1.2GB to ~30MB, but adds CPU overhead. Mitigated: JPEG compression is GPU-accelerated via CIContext.
- **Swift 6 concurrency.** SCStream callbacks on a background DispatchQueue need careful isolation crossing. Mitigated: use `@Sendable` closures and `MainActor.assumeIsolated` at boundaries.

**High risk:**
- **macOS 15 Sequoia screen recording changes.** Apple changed the permission flow to a system-level picker. `CGPreflightScreenCaptureAccess()` may behave differently. Mitigated: the app targets macOS 14+, test on both 14 and 15.

## File Change Summary

| File | Type | Description |
|------|------|-------------|
| `Sources/Services/ScreenCaptureService.swift` | **New** | SCStream lifecycle, frame collection, state machine |
| `Sources/Views/RegionSelectionPanel.swift` | **New** | Full-screen overlay for drag-to-select region |
| `Sources/Views/RecordingIndicatorWindow.swift` | **New** | Floating HUD with red dot + timer during recording |
| `Sources/Models/CaptureHotkeyDefaults.swift` | **New** | UserDefaults wrapper for capture hotkey |
| `Sources/Services/GIFFrameEngine.swift` | Edit | Add `encodeFromCompressedFrames()` for memory-efficient encoding |
| `Sources/App/AppDelegate.swift` | Edit | Second hotkey, capture service init, permission check, state routing |
| `Sources/Views/SettingsView.swift` | Edit | Add capture hotkey recorder row |
| `Sources/Views/HotkeyRecorderView.swift` | Edit | Parameterize save action for reuse |
| `Sources/Info.plist` | Edit | Add `NSScreenCaptureUsageDescription` |

## Known Limitations (Phase 3 MVP)

1. **Region-only capture.** No window detection, no full-screen mode. User must drag a rectangle.
2. **Hardcoded settings.** 10fps, 15s max, 1x resolution, cursor visible. Settings UI for these deferred.
3. **Single-display overlay.** Overlay appears on the screen with the mouse cursor. Multi-display region selection (spanning monitors) not supported.
4. **No audio.** GIFs don't support audio. This is inherent to the format.
5. **JPEG compression artifacts.** The memory optimization strategy introduces minor quality loss in the intermediate representation. Final GIF quality is limited by the 256-color palette anyway, so this is negligible.
6. **No undo for captured GIFs.** Delete from the panel or re-capture. Same pattern as all clipboard items.

## Future Enhancements (Not in Scope)

- Settings UI for fps, max duration, resolution, cursor visibility
- Window capture mode (click to capture a window)
- Animated thumbnail in the clipboard row list
- Capture history / quick re-capture of the same region
- Gifski encoder integration for better color quantization
- Export to file (save GIF to disk)

## References

- Brainstorm: `docs/brainstorms/2026-02-18-gif-screen-capture-brainstorm.md`
- Existing hotkey pattern: `Sources/App/AppDelegate.swift:112-118`
- HotkeyDefaults pattern: `Sources/Views/HotkeyRecorderView.swift:12-31`
- GIFFrameEngine: `Sources/Services/GIFFrameEngine.swift:36-67`
- ClipboardMonitor suppression: `Sources/Services/ClipboardMonitor.swift:41-47`
- ClipboardRecord.upsert: `Sources/Models/ClipboardRecord.swift:76-86`
- GIF paste dual-format: `Sources/Views/FloatingPanel.swift:128-137`
- Permission check pattern: `Sources/App/AppDelegate.swift:88-108`
- FloatingPanel NSPanel subclass: `Sources/Views/FloatingPanel.swift:8-43`
- SettingsView hotkey placement: `Sources/Views/SettingsView.swift:13-19`
- Apple docs: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/)
- Apple docs: [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
- Apple docs: [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)
