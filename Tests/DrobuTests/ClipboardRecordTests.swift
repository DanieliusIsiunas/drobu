import Testing
import Foundation
import GRDB
@testable import DrobuCore

@Suite("ClipboardRecord")
struct ClipboardRecordTests {

    // MARK: - Upsert

    @Test func upsertInsertsNewRecord() throws {
        let db = try makeTestDatabase()
        let record = makeRecord(plainText: "hello", contentHash: "abc123")

        let inserted = try db.pool.write { conn in
            try ClipboardRecord.upsert(record, in: conn)
        }

        #expect(inserted.id != nil)
    }

    @Test func upsertDuplicateUsesNewCreatedAt() throws {
        let db = try makeTestDatabase()
        let hash = "dedup-hash"
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let newDate = Date()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(contentHash: hash, createdAt: oldDate), in: conn)
            try ClipboardRecord.upsert(makeRecord(contentHash: hash, createdAt: newDate), in: conn)

            let all = try ClipboardRecord.fetchRecent(in: conn)
            #expect(all.count == 1)
            #expect(abs(all[0].createdAt.timeIntervalSince(newDate)) < 1)
        }
    }

    // MARK: - FTS5 Search

    @Test func searchFindsMatchingText() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "hello world"), in: conn)
            try ClipboardRecord.upsert(makeRecord(plainText: "goodbye moon", contentHash: "other"), in: conn)
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "hello", in: conn)
        }

        #expect(results.count == 1)
        #expect(results[0].plainText == "hello world")
    }

    @Test func searchPrefixMatchesLastToken() throws {
        let db = try makeTestDatabase()

        _ = try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "clipboard manager"), in: conn)
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "clip", in: conn)
        }

        #expect(results.count == 1)
    }

    @Test func searchMultiTokenMatchesAllTokens() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "hello beautiful world"), in: conn)
            try ClipboardRecord.upsert(makeRecord(plainText: "hello moon", contentHash: "other"), in: conn)
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "hello world", in: conn)
        }

        #expect(results.count == 1)
        #expect(results[0].plainText == "hello beautiful world")
    }

    @Test func searchNonMatchingReturnsEmpty() throws {
        let db = try makeTestDatabase()

        _ = try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "hello world"), in: conn)
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "xyznonexistent", in: conn)
        }

        #expect(results.isEmpty)
    }

    @Test func searchWithQuotesDoesNotCrash() throws {
        let db = try makeTestDatabase()

        _ = try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "say \"hello\" world"), in: conn)
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "\"hello\"", in: conn)
        }

        // Quote escaping should still find the record containing "hello"
        #expect(results.count == 1)
    }

    @Test func searchBySourceApp() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(plainText: "some text", sourceApp: "Safari", contentHash: "safari1"),
                in: conn
            )
            try ClipboardRecord.upsert(
                makeRecord(plainText: "other text", sourceApp: "Terminal", contentHash: "term1"),
                in: conn
            )
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "Safari", in: conn)
        }

        #expect(results.count == 1)
        #expect(results[0].sourceApp == "Safari")
    }

    @Test func searchEmptyQueryReturnsFetchRecent() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "item1", contentHash: "h1"), in: conn)
            try ClipboardRecord.upsert(makeRecord(plainText: "item2", contentHash: "h2"), in: conn)
        }

        let results = try db.pool.read { conn in
            try ClipboardRecord.search(query: "  ", in: conn)
        }

        #expect(results.count == 2)
    }

    // MARK: - UpdatePlainText

    @Test func updatePlainTextRecalculatesHash() throws {
        let db = try makeTestDatabase()
        let oldDate = Date(timeIntervalSinceNow: -3600)

        let original = try db.pool.write { conn in
            try ClipboardRecord.upsert(makeRecord(plainText: "old text", createdAt: oldDate), in: conn)
        }

        try db.pool.write { conn in
            try ClipboardRecord.updatePlainText(id: original.id!, newText: "new text", in: conn)
        }

        let updated = try db.pool.read { conn in
            try ClipboardRecord.fetchRecent(in: conn)
        }

        #expect(updated.count == 1)
        #expect(updated[0].plainText == "new text")
        #expect(updated[0].contentHash == Data("new text".utf8).sha256String)
        #expect(updated[0].createdAt > oldDate)
    }

    @Test func updatePlainTextDeduplicates() throws {
        let db = try makeTestDatabase()
        let targetText = "duplicate target"
        let targetHash = Data(targetText.utf8).sha256String

        try db.pool.write { conn in
            // Insert a record with the hash that "new text" will produce
            try ClipboardRecord.upsert(
                makeRecord(plainText: targetText, contentHash: targetHash),
                in: conn
            )
            // Insert another record we'll update to collide
            let toUpdate = try ClipboardRecord.upsert(
                makeRecord(plainText: "original", contentHash: "different"),
                in: conn
            )
            try ClipboardRecord.updatePlainText(id: toUpdate.id!, newText: targetText, in: conn)

            let all = try ClipboardRecord.fetchRecent(in: conn)
            #expect(all.count == 1)
            #expect(all[0].plainText == targetText)
        }
    }

    // MARK: - UpdateImageData

    @Test func updateImageDataRecalculatesHashAndRefreshesDisplayText() throws {
        let db = try makeTestDatabase()
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let originalData = ImageCropTests.makePNG(width: 100, height: 80)
        let newData = ImageCropTests.makePNG(width: 40, height: 30)

        let original = try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(
                    kind: ClipboardRecord.kindImage,
                    plainText: "Image: 100×80",
                    imageData: originalData,
                    contentHash: originalData.sha256String,
                    createdAt: oldDate
                ),
                in: conn
            )
        }

        try db.pool.write { conn in
            try ClipboardRecord.updateImageData(id: original.id!, newData: newData, in: conn)
        }

        let updated = try db.pool.read { conn in
            try ClipboardRecord.fetchRecent(in: conn)
        }

        #expect(updated.count == 1)
        #expect(updated[0].imageData == newData)
        #expect(updated[0].contentHash == newData.sha256String)
        #expect(updated[0].createdAt > oldDate)
        #expect(updated[0].plainText?.hasPrefix("Image:") == true)
    }

    @Test func updateImageDataDeduplicates() throws {
        let db = try makeTestDatabase()
        let newData = ImageCropTests.makePNG(width: 40, height: 30)
        let newHash = newData.sha256String

        try db.pool.write { conn in
            // Pre-insert a row whose hash equals the NEW data's hash.
            try ClipboardRecord.upsert(
                makeRecord(
                    kind: ClipboardRecord.kindImage,
                    plainText: "collider",
                    imageData: newData,
                    contentHash: newHash
                ),
                in: conn
            )
            // The row we'll update to collide with that hash.
            let toUpdate = try ClipboardRecord.upsert(
                makeRecord(
                    kind: ClipboardRecord.kindImage,
                    plainText: "original",
                    imageData: ImageCropTests.makePNG(width: 100, height: 80),
                    contentHash: "different-hash"
                ),
                in: conn
            )

            try ClipboardRecord.updateImageData(id: toUpdate.id!, newData: newData, in: conn)

            let all = try ClipboardRecord.fetchRecent(in: conn)
            // Exactly one row at the new hash, and it's the updated row.
            #expect(all.count == 1)
            #expect(all[0].id == toUpdate.id)
            #expect(all[0].contentHash == newHash)
        }
    }

    @Test func updateImageDataOnDeletedIdIsSilentNoOp() throws {
        let db = try makeTestDatabase()
        let surviving = ImageCropTests.makePNG(width: 100, height: 80)
        let newData = ImageCropTests.makePNG(width: 40, height: 30)

        try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(
                    kind: ClipboardRecord.kindImage,
                    plainText: "survivor",
                    imageData: surviving,
                    contentHash: surviving.sha256String
                ),
                in: conn
            )

            // Update against an id that doesn't exist — no throw, zero rows changed.
            try ClipboardRecord.updateImageData(id: 999_999, newData: newData, in: conn)

            let all = try ClipboardRecord.fetchRecent(in: conn)
            #expect(all.count == 1)
            #expect(all[0].contentHash == surviving.sha256String)
        }
    }

    // MARK: - Cleanup

    @Test func cleanupDeletesOldRecords() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(plainText: "old", contentHash: "old", createdAt: Date(timeIntervalSinceNow: -31 * 86400)),
                in: conn
            )
            try ClipboardRecord.upsert(
                makeRecord(plainText: "new", contentHash: "new", createdAt: Date()),
                in: conn
            )

            try ClipboardRecord.cleanup(retentionDays: 30, maxCount: 5000, in: conn)

            let remaining = try ClipboardRecord.fetchRecent(in: conn)
            #expect(remaining.count == 1)
            #expect(remaining[0].plainText == "new")
        }
    }

    @Test func cleanupEnforcesMaxCount() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            for i in 0..<5 {
                try ClipboardRecord.upsert(
                    makeRecord(
                        plainText: "item \(i)",
                        contentHash: "hash\(i)",
                        createdAt: Date(timeIntervalSinceNow: Double(-i * 60))
                    ),
                    in: conn
                )
            }

            try ClipboardRecord.cleanup(retentionDays: 365, maxCount: 3, in: conn)

            let remaining = try ClipboardRecord.fetchRecent(in: conn)
            #expect(remaining.count == 3)
            // Most recent items should survive
            #expect(remaining[0].plainText == "item 0")
        }
    }

    @Test func cleanupHandlesBothAgeAndCount() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            // 2 old records (beyond retention)
            for i in 0..<2 {
                try ClipboardRecord.upsert(
                    makeRecord(contentHash: "old\(i)", createdAt: Date(timeIntervalSinceNow: -60 * 86400)),
                    in: conn
                )
            }
            // 4 recent records (within retention, but exceeds maxCount of 2)
            for i in 0..<4 {
                try ClipboardRecord.upsert(
                    makeRecord(contentHash: "new\(i)", createdAt: Date(timeIntervalSinceNow: Double(-i * 60))),
                    in: conn
                )
            }

            try ClipboardRecord.cleanup(retentionDays: 30, maxCount: 2, in: conn)

            let remaining = try ClipboardRecord.fetchRecent(in: conn)
            #expect(remaining.count == 2)
        }
    }

    // MARK: - FetchRecent Ordering

    @Test func fetchRecentReturnsDescendingOrder() throws {
        let db = try makeTestDatabase()

        try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(plainText: "oldest", contentHash: "h1", createdAt: Date(timeIntervalSinceNow: -120)),
                in: conn
            )
            try ClipboardRecord.upsert(
                makeRecord(plainText: "newest", contentHash: "h2", createdAt: Date()),
                in: conn
            )
            try ClipboardRecord.upsert(
                makeRecord(plainText: "middle", contentHash: "h3", createdAt: Date(timeIntervalSinceNow: -60)),
                in: conn
            )

            let items = try ClipboardRecord.fetchRecent(in: conn)
            #expect(items.count == 3)
            #expect(items[0].plainText == "newest")
            #expect(items[1].plainText == "middle")
            #expect(items[2].plainText == "oldest")
        }
    }

    // MARK: - Integration (Full Vertical Slice)

    @Test func fullPipelineInsertDedupSearchCleanup() throws {
        let db = try makeTestDatabase()

        // 1. Insert a text record
        let hash = Data("integration test".utf8).sha256String
        _ = try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(plainText: "integration test", sourceApp: "TestApp", contentHash: hash),
                in: conn
            )
        }

        // 2. Insert duplicate — should deduplicate
        try db.pool.write { conn in
            try ClipboardRecord.upsert(
                makeRecord(plainText: "integration test", sourceApp: "TestApp", contentHash: hash, createdAt: Date()),
                in: conn
            )
            let all = try ClipboardRecord.fetchRecent(in: conn)
            #expect(all.count == 1, "Dedup should keep only one record")
        }

        // 3. Search by text
        let searchResults = try db.pool.read { conn in
            try ClipboardRecord.search(query: "integration", in: conn)
        }
        #expect(searchResults.count == 1, "FTS should find the record")

        // 4. Search by sourceApp
        let appResults = try db.pool.read { conn in
            try ClipboardRecord.search(query: "TestApp", in: conn)
        }
        #expect(appResults.count == 1, "FTS should find by sourceApp")

        // 5. Cleanup — record is fresh, should survive
        try db.pool.write { conn in
            try ClipboardRecord.cleanup(retentionDays: 1, maxCount: 100, in: conn)
            let remaining = try ClipboardRecord.fetchRecent(in: conn)
            #expect(remaining.count == 1, "Fresh record should survive cleanup")
        }

        // 6. Cleanup — force delete by very short retention
        try db.pool.write { conn in
            try ClipboardRecord.cleanup(retentionDays: 0, maxCount: 100, in: conn)
            let remaining = try ClipboardRecord.fetchRecent(in: conn)
            #expect(remaining.isEmpty, "Zero-day retention should delete everything")
        }
    }
}
