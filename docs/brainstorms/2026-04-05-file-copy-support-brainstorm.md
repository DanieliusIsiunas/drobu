# File Copy Support Brainstorm

**Date:** 2026-04-05
**Status:** Ready for planning

## What We're Building

Support file clipboard entries in Drobu. When a user copies files in Finder (PDFs, folders, images, any file), Drobu should capture the file reference, display it with the system icon and path, and paste it back as a proper file paste.

Currently, file copies are either ignored or captured as text-only (just the filename). Alfred, Maccy, and other clipboard managers handle this by storing lightweight file URL references — never the actual file contents.

## Why This Approach

**Store file paths in `plainText`, no schema migration.**

All major clipboard managers (Maccy, Alfred, Clipy) store file URL references, not file contents. We follow the same pattern using the existing `plainText` column — file paths are both the data source for paste-back AND the FTS5 search index. This matches how videos already use `plainText` for metadata.

Alternatives considered:
- New `fileURLs` column: cleaner separation but requires migration for no functional gain
- Quick Look thumbnails: richer previews but slower, requires file to exist, adds complexity
- Separate entries per file: clutters history, loses group context

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Storage | New `kind = "file"`, paths in `plainText` | No migration, FTS5 searchable, proven pattern |
| Display | System icon + filename in list, full path in preview | `NSWorkspace.shared.icon(forFile:)` — fast, always works |
| Multi-file | Single grouped entry ("5 files from Desktop") | Matches Alfred/Maccy, doesn't clutter history |
| Search | Searchable by filename and folder name | Paths in `plainText` → FTS5 indexes automatically |
| Stale files | Delete during hourly cleanup | Check `FileManager.fileExists` in cleanup cycle, remove entries for missing files |
| Previews | No Quick Look thumbnails (v1) | System icon only. QL thumbnails can be a v2 enhancement |
| Paste-back | `writeObjects` with per-file `NSPasteboardItem` | Maccy-proven approach. Each file gets its own item with `.fileURL` type |

## Technical Details from Research

### Pasteboard Types for File Copies
- **`public.file-url`** (`.fileURL`): Modern type, one per file in `pasteboardItems` array
- **`NSFilenamesPboardType`**: Legacy, single plist with all paths. Finder still writes it
- Multiple files = multiple `NSPasteboardItem`s

### Detection in ClipboardMonitor
Check for `.fileURL` type on pasteboard items. Extract file URLs via `URL(dataRepresentation:relativeTo:isAbsolute:)`. Must check BEFORE image/text extraction since Finder puts file URLs alongside other types.

### Record Structure
```
kind: "file"
plainText: "/Users/dan/Desktop/report.pdf"           (single file)
           "/Users/dan/Desktop/a.pdf\n/Users/dan/b.png"  (multi-file)
imageData: nil (system icon fetched at display time)
contentHash: SHA256(sorted newline-joined paths)
```

### Paste-Back (from Maccy source)
```swift
let items: [NSPasteboardItem] = paths.map { path in
    let item = NSPasteboardItem()
    let url = URL(fileURLWithPath: path)
    item.setData(url.dataRepresentation, forType: .fileURL)
    return item
}
pasteboard.writeObjects(items)
```
Must use `writeObjects` (not `setData`) for multi-file paste to work.

### Display
- **List row**: `[system icon] File: report.pdf` or `[folder icon] 3 files from Desktop`
- **Preview panel**: Full paths listed, file size, file type
- **Icon source**: `NSWorkspace.shared.icon(forFile: path)` — falls back to generic type icon if file missing

### Cleanup
Add to existing hourly + launch cleanup cycle:
```swift
// After age/count cleanup, check file entries
for record in fileRecords {
    let paths = record.plainText?.split(separator: "\n") ?? []
    let allMissing = paths.allSatisfy { !FileManager.default.fileExists(atPath: String($0)) }
    if allMissing { delete record }
}
```

## Open Questions

- Should we show individual file icons or a generic "files" icon for multi-file entries?
- For multi-file entries where SOME files are missing, delete only when ALL are gone? Or when any is gone?
- Should the filter tabs include a "Files" tab alongside Text/Image/GIF/Video?

## Next Steps

Run `/workflows:plan` to create the implementation plan.
