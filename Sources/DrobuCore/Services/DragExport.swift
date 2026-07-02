import Foundation
import ImageIO

/// Pure engine for turning `ClipboardRecord`s into drag-out payloads and for
/// reclaiming the temp files those drags leave behind. Kept free of AppKit and
/// view state so the payload matrix, filename synthesis, and reclamation rules
/// are directly unit-testable. `RowDragSourceView` maps `Payload`s to
/// `NSDraggingItem`s; `AppDelegate.runCleanup` / `PanelView` drive reclamation.
///
/// Lives in Services/ alongside the other pure engines (`ImageCrop`,
/// `CropGeometry`, `GIFFrameEngine`, `VideoCropExporter`). Staging does small
/// synchronous file I/O — blobs are already in memory, so a drag-start write is
/// bounded — but the *decisions* (which representation, which filename, which
/// dir gets reclaimed) are pure.
enum DragExport {
    /// A single drag representation. `RowDragSourceView` builds one
    /// `NSDraggingItem` per payload; Chromium and other file-drop targets read
    /// one file URL per pasteboard item, so per-file granularity is required.
    enum Payload: Equatable {
        /// A real file on disk. `secondaryPNG` is raw bitmap bytes offered on the
        /// same pasteboard item for canvas/rich-text targets (image single-drag
        /// only) — a bare file URL cannot carry a second representation.
        case file(URL, secondaryPNG: Data?)
        /// A plain string. Text single-drag inserts as text in editors and becomes
        /// a `.textClipping` in Finder; adding a file URL here would make web and
        /// text targets treat the drop as a file upload instead.
        case string(String)
    }

    // MARK: - Staging location

    /// `~/Library/Application Support/ClipboardHistory/DragStaging`, or a temp-dir
    /// fallback when Application Support can't be resolved (mirrors `videosDirectory`).
    static var stagingDirectory: URL {
        (AppPaths.appSupportDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(AppPaths.directoryName))
            .appendingPathComponent("DragStaging")
    }

    /// Legacy never-cleaned GIF paste temp files written by
    /// `FloatingPanel.writeGIFToPasteboard` — adopted by the age sweep as a freebie.
    static let legacyGifTempPrefix = "ClipboardHistory-"

    // MARK: - Participant selection (pure)

    /// Which items a drag started on `pressed` should carry. A drag from inside an
    /// active multi-selection carries the whole selection; a drag from outside (or
    /// with no multi-selection) carries just the pressed row.
    static func participantIndices(pressed: Int, selection: ClosedRange<Int>, hasMultiSelection: Bool) -> [Int] {
        if hasMultiSelection && selection.contains(pressed) {
            return Array(selection)
        }
        return [pressed]
    }

    // MARK: - Payload construction + staging

    /// Build drag payloads for `records`, staging temp files as needed under
    /// `stagingRoot`. Records with missing backing content contribute nothing, so
    /// an empty result means "don't start a drag" (R6). Throws only on a staging
    /// write failure the caller should treat as an aborted drag (no partial set).
    ///
    /// `multi` (records.count > 1) flips text from string-only to a staged `.txt`
    /// file, so a mixed multi-drag delivers N files.
    static func payloads(for records: [ClipboardRecord], stagingRoot: URL) throws -> [Payload] {
        let multi = records.count > 1
        var result: [Payload] = []
        var usedNames = Set<String>()
        // Track dirs created this call so a mid-loop staging failure doesn't strand
        // already-written clipboard-derived files until the 24h sweep — purge them
        // and rethrow, so the caller aborts with nothing left on disk.
        var stagedDirs: [URL] = []

        do {
            for record in records {
                switch record.kind {
                case ClipboardRecord.kindText:
                    let text = record.plainText ?? ""
                    if multi {
                        let name = uniqueName(textFileName(from: text, createdAt: record.createdAt), in: &usedNames)
                        let url = try stage(Data(text.utf8), as: name, contentHash: record.contentHash, root: stagingRoot, createdDirs: &stagedDirs)
                        result.append(.file(url, secondaryPNG: nil))
                    } else {
                        result.append(.string(text))
                    }

                case ClipboardRecord.kindImage:
                    guard let data = record.imageData, let png = pngData(from: data) else { continue }
                    let name = uniqueName(mediaFileName("Image", ext: "png", createdAt: record.createdAt), in: &usedNames)
                    let url = try stage(png, as: name, contentHash: record.contentHash, root: stagingRoot, createdDirs: &stagedDirs)
                    result.append(.file(url, secondaryPNG: multi ? nil : png))

                case ClipboardRecord.kindGif:
                    guard let data = record.imageData else { continue }
                    let name = uniqueName(mediaFileName("GIF", ext: "gif", createdAt: record.createdAt), in: &usedNames)
                    let url = try stage(data, as: name, contentHash: record.contentHash, root: stagingRoot, createdDirs: &stagedDirs)
                    result.append(.file(url, secondaryPNG: nil))

                case ClipboardRecord.kindVideo:
                    let source = ClipboardRecord.videoPath(for: record.contentHash)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let name = uniqueName(mediaFileName("Video", ext: "mp4", createdAt: record.createdAt), in: &usedNames)
                    let url = try stageExistingFile(source, as: name, contentHash: record.contentHash, root: stagingRoot, createdDirs: &stagedDirs)
                    result.append(.file(url, secondaryPNG: nil))

                case ClipboardRecord.kindFile:
                    // Drag the originals — no staging, no reconcile bucket. Skip stale paths.
                    let paths = record.plainText?.split(separator: "\n").map(String.init) ?? []
                    for path in paths where FileManager.default.fileExists(atPath: path) {
                        result.append(.file(URL(fileURLWithPath: path), secondaryPNG: nil))
                    }

                default:
                    continue
                }
            }
        } catch {
            for dir in stagedDirs { try? FileManager.default.removeItem(at: dir) }
            throw error
        }
        return result
    }

    // MARK: - Reclamation (pure decisions, real I/O)

    /// Purge staging subdirs whose leading content hash is not in `liveContentHashes`
    /// (R14 — a deleted item's staged copy goes immediately). Idempotent; a missing
    /// staging dir is a no-op.
    static func reconcileStaging(liveContentHashes: Set<String>, root: URL) {
        for dir in stagingSubdirectories(in: root) {
            let hash = contentHash(fromStagingDirName: dir.lastPathComponent)
            if let hash, !liveContentHashes.contains(hash) {
                removeStagingItem(dir)
            }
        }
    }

    /// Delete staging subdirs older than `maxAge` (backstop for files whose record
    /// still exists but the drag is long done), plus legacy `ClipboardHistory-*.gif`
    /// paste temp files older than `maxAge` in `legacyTempRoot`. `now` is injected
    /// for testability.
    static func ageSweep(root: URL, legacyTempRoot: URL, maxAge: TimeInterval, now: Date) {
        for dir in stagingSubdirectories(in: root) {
            if let modified = modificationDate(of: dir), now.timeIntervalSince(modified) > maxAge {
                removeStagingItem(dir)
            }
        }
        let legacyFiles = (try? FileManager.default.contentsOfDirectory(
            at: legacyTempRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in legacyFiles
        where file.lastPathComponent.hasPrefix(legacyGifTempPrefix) && file.pathExtension == "gif" {
            if let modified = modificationDate(of: file), now.timeIntervalSince(modified) > maxAge {
                removeStagingItem(file)
            }
        }
    }

    /// Remove the staging subdir(s) for a single deleted record's content hash.
    static func purgeStaging(contentHash: String, root: URL) {
        for dir in stagingSubdirectories(in: root)
        where self.contentHash(fromStagingDirName: dir.lastPathComponent) == contentHash {
            removeStagingItem(dir)
        }
    }

    /// Remove the entire staging tree (for "Delete all history").
    static func purgeAllStaging(root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Log.error("DragExport: purge-all staging failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    /// Delete a staging file/dir, logging a failure so a stranded staged copy of a
    /// deleted item leaves a trail (the reclaim paths are R14's privacy guarantee —
    /// a silent removeItem failure would let it persist unnoticed). Never logs names.
    private static func removeStagingItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.error("DragExport: staging reclaim failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    // MARK: - Filename synthesis (pure)

    /// macOS-screenshot-grammar name from the item's capture time, e.g.
    /// `Drobu Image 2026-07-02 at 14.05.32.png`. Periods in the time (colons are
    /// illegal in Finder names). Capture time (not drag time) keeps repeated drags
    /// of the same item stable.
    static func mediaFileName(_ label: String, ext: String, createdAt: Date) -> String {
        "Drobu \(label) \(timestamp(createdAt)).\(ext)"
    }

    /// Content-derived `.txt` name (like a Finder text clipping), falling back to a
    /// timestamped name when the text has no usable leading characters.
    static func textFileName(from text: String, createdAt: Date) -> String {
        let base = sanitize(String(text.prefix(40)))
        if base.isEmpty {
            return "Drobu Text \(timestamp(createdAt)).txt"
        }
        return "\(String(base.prefix(30))).txt"
    }

    // MARK: - Internals

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    /// Strip characters illegal or awkward in filenames, collapse whitespace, and
    /// drop leading dots. Extension correctness never depends on this (kind fixes
    /// the extension), so this is display sanitation only.
    private static func sanitize(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "/" && scalar != ":" && scalar != "\\"
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var trimmed = collapsed
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// Append a Finder-style ` 2`, ` 3` … suffix (before the extension) on collision
    /// within one drag, and record the chosen name.
    private static func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        guard used.contains(name) else {
            used.insert(name)
            return name
        }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    /// Write `data` into a fresh `<hash>-<UUID>/<name>` staging subdir (dir 0700,
    /// file 0600 per `.claude/rules/file-permission-hardening.md`). Throws on failure.
    private static func stage(_ data: Data, as name: String, contentHash: String, root: URL, createdDirs: inout [URL]) throws -> URL {
        let dir = try makeStagingSubdir(contentHash: contentHash, root: root)
        createdDirs.append(dir)  // track before the write, so a write failure still purges the dir
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Hardlink `source` into a fresh staging subdir under a nice name, falling back
    /// to a copy if linking fails (e.g. cross-volume). O(1) on-volume for video.
    private static func stageExistingFile(_ source: URL, as name: String, contentHash: String, root: URL, createdDirs: inout [URL]) throws -> URL {
        let dir = try makeStagingSubdir(contentHash: contentHash, root: root)
        createdDirs.append(dir)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.linkItem(at: source, to: url)
        } catch {
            try FileManager.default.copyItem(at: source, to: url)
        }
        return url
    }

    private static func makeStagingSubdir(contentHash: String, root: URL) throws -> URL {
        // Create the root explicitly at 0700 first — createDirectory's `attributes`
        // apply only to the leaf, so an intermediate root would otherwise be 0755 and
        // leak staging dir *names* (content hashes) to other local users.
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let dir = root.appendingPathComponent("\(contentHash)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private static func stagingSubdirectories(in root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// A staging dir is named `<contentHash>-<UUID>`; the hash is everything before
    /// the FIRST hyphen. Safe because a SHA-256 hex hash contains no hyphens, so the
    /// first hyphen is always the hash/UUID separator. Returns nil for a name that
    /// doesn't match the shape.
    static func contentHash(fromStagingDirName name: String) -> String? {
        // contentHash is a 64-char lowercase hex SHA-256; the UUID suffix is
        // `-XXXXXXXX-XXXX-...`. Split on the first hyphen after the hash.
        guard let range = name.range(of: "-") else { return nil }
        let hash = String(name[name.startIndex..<range.lowerBound])
        return hash.isEmpty ? nil : hash
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// PNG magic bytes; PNG is written as-is, anything else (TIFF, etc.) is
    /// decoded and re-encoded to PNG so the staged artifact is always `.png`.
    private static func pngData(from data: Data) -> Data? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= pngMagic.count && Array(data.prefix(pngMagic.count)) == pngMagic {
            return data
        }
        guard let cgImage = ImageCrop.decodeBitmap(from: data) else { return nil }
        return ImageCrop.encodePNG(cgImage)
    }
}
