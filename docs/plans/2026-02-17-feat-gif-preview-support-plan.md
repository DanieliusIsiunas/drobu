---
title: "feat: Add GIF preview support"
type: feat
date: 2026-02-17
brainstorm: docs/brainstorms/2026-02-17-gif-support-brainstorm.md
---

# feat: Add GIF Preview Support (Phase 1)

## Overview

Add animated GIF capture, preview, and paste to the clipboard history app. GIFs are stored as a distinct `kind = "gif"`, displayed with native macOS animation in the preview panel, and pasted with a PNG fallback for broad app compatibility.

This is Phase 1 of the GIF support roadmap (Preview → Edit → Screen Capture).

## Problem Statement / Motivation

The app currently ignores GIF data on the clipboard entirely — it only checks for `.png` and `.tiff`. When a user copies a GIF, it's either captured as a static PNG (losing animation) or missed completely. GIFs are a common clipboard format, especially from browsers, messaging apps, and design tools.

## Proposed Solution

1. **Capture** GIF data from the pasteboard (`com.compuserve.gif` type)
2. **Store** as `kind = "gif"` with the existing `imageData` BLOB field (no migration needed)
3. **Preview** with animated playback using NSImageView wrapper (`animates = true`)
4. **Display** metadata: dimensions, file size, duration, frame count
5. **Paste** with dual format: GIF data + static PNG fallback

## Technical Approach

### Change 1: Add GIF kind constant

**File:** `Sources/Models/ClipboardRecord.swift`

Add alongside existing kind constants:

```swift
static let kindGif = "gif"
```

No schema migration needed — `kind` is a TEXT column and `imageData` is a format-agnostic BLOB.

### Change 2: Capture GIF data from clipboard

**File:** `Sources/Services/ClipboardMonitor.swift`

In `extractRecord(from:)`, insert a GIF check between text and image extraction (line ~112):

- Check for `NSPasteboard.PasteboardType("com.compuserve.gif")` data
- 20MB size cap: `guard gifData.count <= 20_000_000`
- Hash raw GIF bytes with SHA256
- Store `sourceApp` name in `plainText` for FTS searchability (same pattern as images, line 119)
- Return record with `kind = ClipboardRecord.kindGif`

Priority order becomes: **text > gif > image**

```
// Pseudocode for extractRecord flow:
1. Check .string → return kindText
2. Check com.compuserve.gif → return kindGif (NEW)
3. Check .png / .tiff → return kindImage
```

### Change 3: Animated GIF preview

**New file:** `Sources/Views/AnimatedGIFView.swift`

NSViewRepresentable wrapping NSImageView. Follow the minimal pattern from `VisualEffectBackground` (ClipboardPanelView.swift:374-384):

```swift
struct AnimatedGIFView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        // Load GIF
        if let image = NSImage(data: data) {
            imageView.image = image
        }
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Re-set image if data changes (user selects different item)
        if let image = NSImage(data: data) {
            nsView.image = image
        }
        nsView.animates = true
    }
}
```

### Change 4: Update PreviewPanel

**File:** `Sources/Views/PreviewPanel.swift`

In `previewContent(for:)` (line 32-39), add a GIF branch:

```swift
case ClipboardRecord.kindGif:
    gifPreview(for: item)
```

New `gifPreview` method uses `AnimatedGIFView` instead of `Image(nsImage:)`.

In `metadataBar(for:)` (line 84-109), add GIF metadata:
- Dimensions (from NSImage.size)
- File size (ByteCountFormatter)
- Duration and frame count (from CGImageSource — see Change 6)

Display format: `320x240 (1.2 MB) | 3.2s, 48 frames`

### Change 5: Update row view

**File:** `Sources/Views/ClipboardRowView.swift`

In `contentView` (line 54-69), add GIF case:

```swift
case ClipboardRecord.kindGif:
    // Same as image but with "GIF:" prefix and duration
    Text("GIF: \(w)x\(h) (\(sizeStr), \(durationStr))")
```

In `appIcon` (line 38-49), add GIF icon:

```swift
item.kind == ClipboardRecord.kindGif ? "play.rectangle" : "photo"
```

Duration extracted via a helper (see Change 6). If extraction fails, omit duration gracefully.

### Change 6: GIF metadata extraction helper

**New addition to:** `Sources/Models/ClipboardRecord.swift` (or a small extension)

Static helper using CGImageSource (read-only, not for rendering):

```swift
static func gifMetadata(from data: Data) -> (frameCount: Int, duration: Double)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let count = CGImageSourceGetCount(source)
    var duration: Double = 0
    for i in 0..<count {
        if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
           let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                     ?? gifProps[kCGImagePropertyGIFDelayTime as String] as? Double
                     ?? 0.1
            duration += delay
        }
    }
    return (count, duration)
}
```

### Change 7: Paste GIF with PNG fallback

**File:** `Sources/Views/FloatingPanel.swift`

In the paste logic (around line 132-165), add GIF handling:

**Single-item paste (GIF):**
1. `pasteboard.clearContents()`
2. Write GIF data: `pasteboard.setData(gifData, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))`
3. Generate PNG fallback at paste time:
   ```swift
   if let nsImage = NSImage(data: gifData),
      let tiffData = nsImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) {
       pasteboard.setData(pngData, forType: .png)
   }
   ```
4. `suppressNextChange()` — writing multiple types to one item = one changeCount increment

**Multi-item paste:** Same approach, include GIF items in the image paste sequence.

## Acceptance Criteria

- [x] Copying a GIF in any app captures it as `kind = "gif"` in clipboard history
- [x] GIF appears in the list with "GIF:" prefix, dimensions, size, and duration
- [x] Selecting a GIF shows animated preview in the preview panel
- [x] GIF animation plays automatically, loops continuously
- [x] Pressing Enter/clicking pastes GIF data to the target app
- [x] Apps that don't support GIF receive a static PNG instead
- [x] GIF deduplication works (same GIF copied twice = single entry moved to top)
- [x] GIFs over 20MB are silently skipped (same as image cap behavior)
- [x] Source app icon and name displayed correctly for GIF items
- [x] GIFs searchable by source app name
- [x] Existing text and image functionality unaffected

## Known Limitations (Phase 1)

1. **GIF + text clipboard:** When an app puts both text and GIF on the clipboard, text wins (per priority rule). This affects some browser/messaging app copies that include a URL alongside the GIF. Acceptable for v1 — can add a URL-detection heuristic later if users report issues.

2. **Single-frame GIFs:** Stored as `kind = "gif"` even though they're effectively static images. No downgrade detection. Acceptable — no user-visible difference.

3. **No GIF editing:** Preview only. Trim and speed controls are Phase 2.

4. **No animated thumbnails in list:** List shows text metadata, not a thumbnail. Preview panel is where animation lives.

## Dependencies & Risks

**Low risk:**
- No database migration needed
- NSImageView GIF animation is a mature macOS API
- CGImageSource metadata extraction is well-documented
- All changes are additive (existing text/image paths untouched)

**Medium risk:**
- Memory usage with large GIFs (20MB). Mitigated: NSImageView lazy-loads frames. SQLite streams blob data. Monitor: if issues arise, add thumbnail caching.
- PNG fallback generation at paste time adds ~50-100ms. Acceptable for user-initiated action.

## File Change Summary

| File | Type | Description |
|------|------|-------------|
| `Sources/Models/ClipboardRecord.swift` | Edit | Add `kindGif` constant + `gifMetadata()` helper |
| `Sources/Services/ClipboardMonitor.swift` | Edit | Add GIF capture between text and image checks |
| `Sources/Views/AnimatedGIFView.swift` | **New** | NSViewRepresentable for animated GIF display |
| `Sources/Views/PreviewPanel.swift` | Edit | Add GIF branch in preview + metadata |
| `Sources/Views/ClipboardRowView.swift` | Edit | Add GIF row display + icon |
| `Sources/Views/FloatingPanel.swift` | Edit | Add GIF paste with PNG fallback |

## References

- Brainstorm: `docs/brainstorms/2026-02-17-gif-support-brainstorm.md`
- Existing NSViewRepresentable patterns: `Sources/Views/EditableTextView.swift`, `Sources/Views/HotkeyRecorderView.swift`
- Existing image paste logic: `Sources/Views/FloatingPanel.swift:231-272`
- Apple docs: [NSImageView.animates](https://developer.apple.com/documentation/appkit/nsimageview/1404950-animates)
- Apple docs: [CGImageSource](https://developer.apple.com/documentation/imageio/cgimagesource)
