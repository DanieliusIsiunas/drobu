import Foundation

/// Display verb for the ⌘→ edit action, by content **kind alone** — no data-availability
/// gate. Used by the per-row VoiceOver hint, where running `ImageCrop.isBitmapData` (a
/// CGImageSource build over the whole image `Data`) or a `FileManager` check on every
/// visible row per render would be a hot-path cost. A rare non-bitmap image / missing
/// video row therefore announces its verb even though ⌘→ would no-op there — an accepted,
/// cheap over-promise for a spoken hint (see `.claude/rules/accessibility.md`).
///
/// text → "edit", image/gif → "crop", video → "trim", file/other → nil.
func editVerb(forKind kind: String) -> String? {
    switch kind {
    case ClipboardRecord.kindText: return "edit"
    case ClipboardRecord.kindImage, ClipboardRecord.kindGif: return "crop"
    case ClipboardRecord.kindVideo: return "trim"
    default: return nil
    }
}

/// The single source of truth for whether ⌘→ does anything for `item` and, if so, its
/// display verb. Returns nil when the item's editable data is unavailable, so any hint
/// that shows it never advertises a no-op. This MUST stay in sync with the ⌘→ entry gate
/// in `PanelView.handleClipboardKeyPress` — both call this function.
///
/// The two facts not derivable from the record alone are passed in by the caller:
///   - `isBitmapImage`   — `item.imageData.map(ImageCrop.isBitmapData) ?? false`
///   - `videoFileExists` — `FileManager` check on `ClipboardRecord.videoPath(for:)`
/// `plainText` / `imageData` are stored properties, read directly. No filesystem or
/// ImageIO calls happen inside this function — it stays pure and unit-testable.
func editActionVerb(for item: ClipboardRecord,
                    isBitmapImage: Bool,
                    videoFileExists: Bool) -> String? {
    guard let verb = editVerb(forKind: item.kind) else { return nil }
    switch item.kind {
    case ClipboardRecord.kindText: return item.plainText != nil ? verb : nil
    case ClipboardRecord.kindImage: return isBitmapImage ? verb : nil
    case ClipboardRecord.kindGif: return item.imageData != nil ? verb : nil
    case ClipboardRecord.kindVideo: return videoFileExists ? verb : nil
    default: return nil
    }
}
