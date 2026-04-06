import Foundation
import GRDB
@testable import DrobuCore

func makeTestDatabase() throws -> AppDatabase {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("drobu-test-\(UUID().uuidString)")
        .appendingPathExtension("sqlite")
    return try AppDatabase(path: tmp.path)
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
