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
