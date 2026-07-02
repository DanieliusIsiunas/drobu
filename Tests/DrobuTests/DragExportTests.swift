import AppKit
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DrobuCore

@Suite("DragExport")
struct DragExportTests {

    // MARK: - Helpers

    /// Fresh temp staging root per test — never the real app-support tree.
    private func makeStagingRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drobu-drag-tests")
            .appendingPathComponent(UUID().uuidString)
        return root
    }

    private func fixedDate() -> Date {
        // 2026-07-02 14:05:32 UTC-independent: build from components in the current
        // calendar so the formatted string matches the local formatter output.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 2
        comps.hour = 14; comps.minute = 5; comps.second = 32
        return Calendar.current.date(from: comps)!
    }

    private static func makePNG(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func makeTIFF(width: Int, height: Int) -> Data {
        let png = makePNG(width: width, height: height)
        let rep = NSBitmapImageRep(data: png)!
        return rep.representation(using: .tiff, properties: [:])!
    }

    private func fileURL(_ payload: DragExport.Payload) -> URL? {
        if case let .file(url, _) = payload { return url }
        return nil
    }

    // MARK: - Filename grammar

    @Test func mediaFileNameUsesScreenshotGrammarFromCaptureTime() {
        let name = DragExport.mediaFileName("Image", ext: "png", createdAt: fixedDate())
        #expect(name == "Drobu Image 2026-07-02 at 14.05.32.png")
        #expect(!name.contains(":"))
    }

    @Test func textFileNameDerivesFromLeadingContent() {
        let name = DragExport.textFileName(from: "hello world this is a note", createdAt: fixedDate())
        #expect(name.hasSuffix(".txt"))
        #expect(name.hasPrefix("hello world"))
    }

    @Test func textFileNameSanitizesIllegalCharacters() {
        let name = DragExport.textFileName(from: "re: budget / plan\nsecond line", createdAt: fixedDate())
        #expect(!name.contains(":"))
        #expect(!name.contains("/"))
        #expect(!name.hasPrefix("."))
    }

    @Test func emptyTextFallsBackToTimestampName() {
        let name = DragExport.textFileName(from: "   \n  ", createdAt: fixedDate())
        #expect(name == "Drobu Text 2026-07-02 at 14.05.32.txt")
    }

    @Test func textFileNameStripsLeadingDots() {
        let name = DragExport.textFileName(from: "...hidden note", createdAt: fixedDate())
        #expect(!name.hasPrefix("."))  // must not become an invisible dotfile
        #expect(name.hasPrefix("hidden note"))
    }

    @Test func collidingNamesInOneDragGetFinderStyleCounter() throws {
        let root = makeStagingRoot()
        // Two GIF records with the same capture second → same synthesized base name.
        let a = makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47, 0x01]), contentHash: "gifA", createdAt: fixedDate())
        let b = makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47, 0x02]), contentHash: "gifB", createdAt: fixedDate())
        let names = try DragExport.payloads(for: [a, b], stagingRoot: root)
            .compactMap { fileURL($0)?.lastPathComponent }
        #expect(names.count == 2)
        #expect(Set(names).count == 2)  // distinct
        #expect(names.contains { $0.hasSuffix(" 2.gif") })
    }

    // MARK: - Participant rule

    @Test func participantInsideMultiSelectionDragsWholeSelection() {
        let indices = DragExport.participantIndices(pressed: 2, selection: 1...3, hasMultiSelection: true)
        #expect(indices == [1, 2, 3])
    }

    @Test func participantOutsideSelectionDragsPressedOnly() {
        let indices = DragExport.participantIndices(pressed: 5, selection: 1...3, hasMultiSelection: true)
        #expect(indices == [5])
    }

    @Test func participantWithNoMultiSelectionDragsPressedOnly() {
        let indices = DragExport.participantIndices(pressed: 2, selection: 2...2, hasMultiSelection: false)
        #expect(indices == [2])
    }

    // MARK: - Payload matrix

    @Test func textSingleDragIsStringNoFile() throws {
        let root = makeStagingRoot()
        let payloads = try DragExport.payloads(for: [makeRecord(kind: .init(ClipboardRecord.kindText), plainText: "hi")], stagingRoot: root)
        #expect(payloads == [.string("hi")])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func textInMultiDragIsStagedTxtFile() throws {
        let root = makeStagingRoot()
        let text = makeRecord(kind: ClipboardRecord.kindText, plainText: "note body", createdAt: fixedDate())
        let image = makeRecord(kind: ClipboardRecord.kindImage, imageData: Self.makePNG(width: 4, height: 4))
        let payloads = try DragExport.payloads(for: [text, image], stagingRoot: root)
        #expect(payloads.count == 2)
        let txt = payloads.compactMap(fileURL).first { $0.pathExtension == "txt" }
        #expect(txt != nil)
        #expect(FileManager.default.fileExists(atPath: txt!.path))
    }

    @Test func pngImageStagedAsIsWithSecondaryData() throws {
        let root = makeStagingRoot()
        let png = Self.makePNG(width: 8, height: 6)
        let payloads = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindImage, imageData: png)], stagingRoot: root)
        guard case let .file(url, secondary)? = payloads.first else { Issue.record("expected file payload"); return }
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == png)
        #expect(secondary == png)  // single image drag carries raw bytes too
    }

    @Test func tiffImageReencodedToPNG() throws {
        let root = makeStagingRoot()
        let tiff = Self.makeTIFF(width: 10, height: 7)
        let payloads = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindImage, imageData: tiff)], stagingRoot: root)
        guard let url = payloads.first.flatMap(fileURL) else { Issue.record("expected file payload"); return }
        #expect(url.pathExtension == "png")
        let dims = ImageCrop.decodeBitmap(from: try Data(contentsOf: url)).map { ($0.width, $0.height) }
        #expect(dims?.0 == 10 && dims?.1 == 7)
    }

    @Test func gifStagedByteIdentical() throws {
        let root = makeStagingRoot()
        let gifBytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x02, 0x03])
        let payloads = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: gifBytes)], stagingRoot: root)
        guard let url = payloads.first.flatMap(fileURL) else { Issue.record("expected file payload"); return }
        #expect(url.pathExtension == "gif")
        #expect(try Data(contentsOf: url) == gifBytes)
    }

    @Test func undecodableImageYieldsNoPayload() throws {
        let root = makeStagingRoot()
        // Not PNG-magic and not a decodable bitmap → gate rejects (like missing video).
        let payloads = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindImage, imageData: Data([0x00, 0x01, 0x02]))], stagingRoot: root)
        #expect(payloads.isEmpty)
    }

    @Test func missingVideoYieldsNoPayload() throws {
        let root = makeStagingRoot()
        // No file written at videoPath(for:) → gate rejects.
        let payloads = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindVideo, contentHash: "deadbeefvideo")], stagingRoot: root)
        #expect(payloads.isEmpty)
    }

    @Test func fileKindKeepsExistingPathsSkipsDeleted() throws {
        let root = makeStagingRoot()
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("drobu-file-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }
        let deleted = "/tmp/drobu-does-not-exist-\(UUID().uuidString)"
        let record = makeRecord(kind: ClipboardRecord.kindFile, plainText: "\(existing.path)\n\(deleted)")
        let payloads = try DragExport.payloads(for: [record], stagingRoot: root)
        #expect(payloads.count == 1)
        #expect(fileURL(payloads[0])?.path == existing.path)
    }

    @Test func allPathsDeletedYieldsNoPayload() throws {
        let root = makeStagingRoot()
        let record = makeRecord(kind: ClipboardRecord.kindFile, plainText: "/tmp/nope-\(UUID().uuidString)")
        #expect(try DragExport.payloads(for: [record], stagingRoot: root).isEmpty)
    }

    @Test func stagedDirsCarryContentHashPrefix() throws {
        let root = makeStagingRoot()
        let record = makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47, 0x49, 0x46]), contentHash: "abc123hash")
        _ = try DragExport.payloads(for: [record], stagingRoot: root)
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(dirs.count == 1)
        #expect(DragExport.contentHash(fromStagingDirName: dirs[0]) == "abc123hash")
    }

    @Test func stagedFilePermissionsAreOwnerOnly() throws {
        let root = makeStagingRoot()
        let record = makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47, 0x49, 0x46]))
        let payloads = try DragExport.payloads(for: [record], stagingRoot: root)
        guard let url = payloads.first.flatMap(fileURL) else { Issue.record("expected file payload"); return }
        let filePerms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(filePerms == 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
    }

    // MARK: - Reconcile (R14)

    @Test func reconcileDeletesDirsWithNoLiveRecord() throws {
        let root = makeStagingRoot()
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "livehash")], stagingRoot: root)
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "deadhash")], stagingRoot: root)

        DragExport.reconcileStaging(liveContentHashes: ["livehash"], root: root)

        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(dirs.count == 1)
        #expect(DragExport.contentHash(fromStagingDirName: dirs[0]) == "livehash")
    }

    @Test func purgeStagingRemovesOnlyMatchingHash() throws {
        let root = makeStagingRoot()
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "keepme")], stagingRoot: root)
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "purgeme")], stagingRoot: root)

        DragExport.purgeStaging(contentHash: "purgeme", root: root)

        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(dirs.count == 1)
        #expect(DragExport.contentHash(fromStagingDirName: dirs[0]) == "keepme")
    }

    @Test func purgeAllStagingRemovesTree() throws {
        let root = makeStagingRoot()
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "any")], stagingRoot: root)
        DragExport.purgeAllStaging(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Age sweep (R10)

    @Test func ageSweepDeletesOldStagingKeepsNew() throws {
        let root = makeStagingRoot()
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "old")], stagingRoot: root)
        // Backdate the first subdir past the floor; add a second at natural (fresh) mtime.
        let oldSubdir = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: oldSubdir.path)
        _ = try DragExport.payloads(for: [makeRecord(kind: ClipboardRecord.kindGif, imageData: Data([0x47]), contentHash: "fresh")], stagingRoot: root)

        let legacyRoot = makeStagingRoot()
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)

        DragExport.ageSweep(root: root, legacyTempRoot: legacyRoot, maxAge: 24 * 3600, now: Date())

        // Old one gone, fresh one kept — asserts the age comparison, not blanket deletion.
        let survivors = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(survivors.count == 1)
        #expect(DragExport.contentHash(fromStagingDirName: survivors[0]) == "fresh")
    }

    @Test func ageSweepReclaimsLegacyGifTempsOnly() throws {
        let root = makeStagingRoot()
        let legacyRoot = makeStagingRoot()
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)

        let oldGif = legacyRoot.appendingPathComponent("ClipboardHistory-\(UUID().uuidString).gif")
        try Data([0x47]).write(to: oldGif)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: oldGif.path)

        // A matching-prefix but FRESH gif must be kept (asserts the age comparison).
        let freshGif = legacyRoot.appendingPathComponent("ClipboardHistory-\(UUID().uuidString).gif")
        try Data([0x47]).write(to: freshGif)

        let unrelated = legacyRoot.appendingPathComponent("other-file.gif")
        try Data([0x47]).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: unrelated.path)

        DragExport.ageSweep(root: root, legacyTempRoot: legacyRoot, maxAge: 24 * 3600, now: Date())

        #expect(!FileManager.default.fileExists(atPath: oldGif.path))   // old + matching prefix → deleted
        #expect(FileManager.default.fileExists(atPath: freshGif.path))  // fresh + matching prefix → kept
        #expect(FileManager.default.fileExists(atPath: unrelated.path)) // old but wrong prefix → untouched
    }

    @Test func reclamationOverMissingRootIsNoOp() {
        let root = makeStagingRoot()  // never created
        DragExport.reconcileStaging(liveContentHashes: [], root: root)
        DragExport.ageSweep(root: root, legacyTempRoot: root, maxAge: 1, now: Date())
        DragExport.purgeStaging(contentHash: "x", root: root)
        DragExport.purgeAllStaging(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
