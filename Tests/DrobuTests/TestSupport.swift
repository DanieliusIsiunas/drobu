import AppKit
import Foundation
import GRDB
@testable import DrobuCore

/// Shared directory for test databases, cleaned at the start of each test process.
private let testDatabaseDirectory: URL = {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("drobu-tests")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

func makeTestDatabase() throws -> AppDatabase {
    let path = testDatabaseDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    return try AppDatabase(path: path.path)
}

// MARK: - MockPasteboardItem

@MainActor
final class MockPasteboardItem: PasteboardItemReading {
    var types: [NSPasteboard.PasteboardType]
    private var dataStore: [NSPasteboard.PasteboardType: Data]
    private var stringStore: [NSPasteboard.PasteboardType: String]

    init(
        types: [NSPasteboard.PasteboardType] = [],
        data: [NSPasteboard.PasteboardType: Data] = [:],
        strings: [NSPasteboard.PasteboardType: String] = [:]
    ) {
        self.types = types
        self.dataStore = data
        self.stringStore = strings
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? { dataStore[type] }
    func string(forType type: NSPasteboard.PasteboardType) -> String? { stringStore[type] }

    // MARK: Factories

    static func text(_ string: String) -> MockPasteboardItem {
        MockPasteboardItem(
            types: [.string],
            strings: [.string: string]
        )
    }

    static func gif(_ data: Data) -> MockPasteboardItem {
        MockPasteboardItem(
            types: [.gif],
            data: [.gif: data]
        )
    }

    static func image(_ data: Data, type: NSPasteboard.PasteboardType = .png) -> MockPasteboardItem {
        MockPasteboardItem(
            types: [type],
            data: [type: data]
        )
    }
}

// MARK: - ClipboardRecord Factory

func makeRecord(
    kind: String = ClipboardRecord.kindText,
    plainText: String? = "test text",
    imageData: Data? = nil,
    sourceApp: String? = nil,
    sourceBundleId: String? = nil,
    contentHash: String? = nil,
    createdAt: Date = Date()
) -> ClipboardRecord {
    ClipboardRecord(
        kind: kind,
        plainText: plainText,
        imageData: imageData,
        sourceApp: sourceApp,
        sourceBundleId: sourceBundleId,
        contentHash: contentHash ?? Data((plainText ?? UUID().uuidString).utf8).sha256String,
        createdAt: createdAt
    )
}
