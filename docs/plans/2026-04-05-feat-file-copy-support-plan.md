---
title: "feat: File Copy Support"
type: feat
date: 2026-04-05
---

# feat: File Copy Support

## Overview

When a user copies files in Finder (PDFs, folders, images, any file), Drobu should capture the file reference, display it with the system icon and path, and paste it back as a proper file paste. Currently, file copies are either ignored or captured as plain text (just the path string).

All major clipboard managers (Maccy, Alfred, Clipy) handle this by storing lightweight file URL references — never the actual file contents.

## Problem Statement

Drobu's `ClipboardMonitor.extractRecord()` checks for GIF, text, and image pasteboard types but has no handling for `public.file-url`. When a user copies a file in Finder, the pasteboard contains both `.fileURL` and `.string` types — so the text check captures the raw path string instead of creating a proper file entry with icon, metadata, and correct paste-back behavior.

## Proposed Solution

Add a new content kind `"file"` that stores file path(s) in `plainText`, displays system file icons, and pastes back via `pasteboard.writeObjects()` with `NSURL` objects.

**No schema migration needed** — reuses existing `plainText` column for paths and `imageData` stays nil (icons fetched at display time).

## Technical Approach

### Detection Priority (Critical)

File URL detection lives **entirely in the pre-scan phase** of `checkForChanges()` — before the per-item loop. It does NOT go inside `extractRecord()`.

New priority order:
1. **Pre-scan: File URL(s)** (NEW — collects all `.fileURL` items, excludes `.gif`)
2. Per-item loop (existing): GIF raw data → GIF via file URL → text → image

**Disambiguation rule:** Only trigger file detection when `.fileURL` pasteboard type is present with a `file://` scheme. If only `.string` is present (e.g., IDE "copy path"), treat as text.

**Image files copied in Finder** (e.g., `photo.png`): Captured as `kindFile`, not `kindImage`. The user copied a FILE, not image content. Matches Maccy/Alfred behavior.

### Multi-File Grouping & Mixed Pasteboard Handling (Critical)

Finder puts **one `NSPasteboardItem` per file** when copying multiple files. The current `checkForChanges()` loop iterates items individually. Must restructure to pre-scan:

1. **Pre-scan** all pasteboard items for `.fileURL` type
2. If **ALL items** have `.fileURL` → collect paths into single `ClipboardRecord(kind: "file")`, skip per-item loop
3. If **SOME items** have `.fileURL` but others don't (mixed pasteboard) → fall through to per-item loop, skip file-URL items there
4. If **NO items** have `.fileURL` → existing per-item processing unchanged

```
// Sources/Services/ClipboardMonitor.swift — checkForChanges()

// NEW: Pre-scan for file URLs across all items
let fileItems = items.filter { item in
    guard let urlString = item.string(forType: .fileURL),
          let url = URL(string: urlString),
          url.scheme == "file",
          url.pathExtension.lowercased() != "gif" else { return false }
    return true
}

if !fileItems.isEmpty && fileItems.count == items.count {
    // ALL items are file URLs → single grouped file record
    let paths = fileItems.compactMap { item -> String? in
        guard let urlString = item.string(forType: .fileURL),
              let url = URL(string: urlString) else { return nil }
        return url.path
    }.sorted()
    let joined = paths.joined(separator: "\n")
    let hash = Data(joined.utf8).sha256String
    // ... upsert ClipboardRecord(kind: .kindFile, plainText: joined, contentHash: hash)
    return  // Skip per-item processing
}

// Existing per-item loop — skip items already identified as file URLs
let fileItemSet = Set(fileItems.map { ObjectIdentifier($0) })
for item in items {
    if fileItemSet.contains(ObjectIdentifier(item)) { continue }
    // ... existing extractRecord() logic
}
```

### Record Structure

```
kind:        "file"
plainText:   "/Users/dan/Desktop/report.pdf"              (single)
             "/Users/dan/Desktop/a.pdf\n/Users/dan/b.png" (multi, sorted)
imageData:   nil (system icon fetched at display time)
contentHash: SHA256(sorted newline-joined paths)
sourceApp:   frontmost app name
sourceBundleId: frontmost app bundle ID
```

### Display (Minimal — reuse text preview)

**ClipboardRowView — List Row:**
- Icon fallback SF Symbol: `"doc.fill"` for single file, `"doc.on.doc.fill"` for multi-file
- Content text:
  - Single file: `"report.pdf"` (filename extracted from path)
  - Multi-file: `"3 files"` (count only, no directory heuristic)

**PreviewPanel & LargePreviewPanel:**
- Reuse existing `default:` text preview path — `plainText` already contains the paths, which display as readable text
- Add file-specific metadata bar line (file count, or file size for single file if trivially available)
- No custom file preview views needed for v1

### Paste-Back

Use `NSURL` objects via `writeObjects` — the same proven pattern as the existing video paste-back (`FloatingPanel.swift:192`). This is what Finder expects.

```
// Sources/Views/FloatingPanel.swift — pasteItem()

case ClipboardRecord.kindFile:
    guard let text = record.plainText else { break }
    let paths = text.split(separator: "\n").map(String.init)
    let urls: [NSURL] = paths.compactMap { path in
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }
    guard !urls.isEmpty else { break }
    pasteboard.writeObjects(urls)
```

**Key rules:**
- Must use `writeObjects` with `NSURL` (not `NSPasteboardItem` with `.fileURL`) for Finder compatibility
- `writeObjects` triggers **one** `changeCount` increment → `suppressNextChange()` is sufficient
- Skip files that no longer exist at paste time

**Multi-paste:** For v1, file entries in multi-select paste are handled as individual `writeObjects` calls (same as video). No new `PasteOperation` case needed — treat file like video in `pasteItems()`.

### Cleanup

Add to existing hourly + launch cleanup cycle in `AppDelegate.runCleanup()`. Use a cursor to avoid loading all records into memory:

```
// After age/count cleanup, check file entries
try dbPool.write { db in
    let cursor = try ClipboardRecord
        .filter(Column("kind") == ClipboardRecord.kindFile)
        .fetchCursor(db)
    while let record = try cursor.next() {
        let paths = record.plainText?.split(separator: "\n").map(String.init) ?? []
        let allMissing = paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
        if allMissing {
            try record.delete(db)
        }
    }
}
```

**Multi-file policy:** Delete entry only when **ALL** files in the group are missing. At paste time, only include files that still exist.

### Filter Tab

Add to `PanelView`:
- `kindOrder`: append `ClipboardRecord.kindFile` after `kindVideo`
- `kindLabels`: add `"file": "File"`

Tab only appears when file entries exist in the database (existing filter logic handles this).

## Edge Cases & Decisions

| Edge Case | Decision |
|-----------|----------|
| Image file (`.png`) copied in Finder | Captured as `kindFile`, not `kindImage` — user copied a FILE |
| `.gif` file copied in Finder | Stays as `kindGif` — excluded from pre-scan by extension check |
| Mixed pasteboard (file URLs + other types) | Fall through to per-item loop, skip file-URL items |
| Symlinks | Store symlink path as-is, don't resolve |
| External/network drive files | Stored normally; cleaned up when volume unmounted and all files missing |
| Promised file URLs (Safari downloads) | Ignored — only handle `file://` scheme |
| Drag-and-drop between apps | Not captured — uses separate drag pasteboard |
| Edit mode (`Cmd+Right`) on file entries | No-op — files aren't editable |
| Paste-back when file is deleted | Silently skip missing files. Multi-file: paste only existing ones |
| Suppression after paste | Single `suppressNextChange()` — one change count increment |
| Same file, different path (renamed/moved) | Different hash → separate entries (hash is path-based) |
| Copy `A` alone, then later copy `A+B` | Two separate entries — different path sets, different hashes |
| FTS search overlap with text entries | Acceptable for v1 — `unicode61` tokenizes paths naturally |

## Acceptance Criteria

- [x] Copying a single file in Finder creates a `kindFile` entry with filename display
- [x] Copying multiple files creates a single grouped entry ("N files")
- [ ] Copying a folder creates a `kindFile` entry with folder icon
- [ ] Pasting a file entry back writes `NSURL` objects — Finder accepts it
- [ ] Multi-file paste-back works — all files appear in target app
- [x] Searching by filename finds file entries via FTS5
- [x] "File" filter tab appears when file entries exist
- [x] Hourly cleanup removes entries where all files have been deleted
- [x] GIF files copied in Finder still captured as `kindGif` (not `kindFile`)
- [x] Image files (`.png`, `.jpg`) copied in Finder captured as `kindFile`
- [x] Preview panel shows file paths (reuses text preview)
- [x] Deduplication works — re-copying same files moves entry to top
- [x] `suppressNextChange()` prevents re-capture after paste-back
- [x] Mixed pasteboard (file + non-file items) handles both correctly

## Files to Modify

| File | Change |
|------|--------|
| `Sources/Models/ClipboardRecord.swift` | Add `static let kindFile = "file"` |
| `Sources/Services/ClipboardMonitor.swift` | Pre-scan for file URLs in `checkForChanges()`, skip file items in per-item loop |
| `Sources/Views/FloatingPanel.swift` | Add `kindFile` case in `pasteItem()`, handle in `pasteItems()` like video |
| `Sources/Views/PanelView.swift` | Add to `kindOrder` and `kindLabels` |
| `Sources/Views/ClipboardRowView.swift` | Add SF Symbol icon + filename display for `kindFile` |
| `Sources/Views/PreviewPanel.swift` | Add `kindFile` to metadata bar (file count/size) |
| `Sources/Views/LargePreviewPanel.swift` | Route `kindFile` to text preview (may need no change if default handles it) |
| `Sources/App/AppDelegate.swift` | Add file existence check in cleanup cycle |

## References

- Brainstorm: `docs/brainstorms/2026-04-05-file-copy-support-brainstorm.md`
- [Maccy Clipboard.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift) — `writeObjects` pattern for file URLs
- `NSPasteboard.PasteboardType.fileURL` — modern type for file copies
- `NSWorkspace.shared.icon(forFile:)` — system file icon API
- Existing video paste-back at `FloatingPanel.swift:192` — `NSURL` + `writeObjects` pattern
