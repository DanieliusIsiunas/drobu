import CryptoKit
import GRDB
import Foundation
import ImageIO

struct ClipboardRecord: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var kind: String
    var plainText: String?
    var imageData: Data?
    var sourceApp: String?
    var sourceBundleId: String?
    var contentHash: String
    var createdAt: Date

    static let databaseTableName = "clipboardItem"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Kinds

extension ClipboardRecord {
    static let kindText = "text"
    static let kindImage = "image"
    static let kindGif = "gif"
}

// MARK: - Query Methods

extension ClipboardRecord {

    /// Fetch recent items ordered by creation date descending.
    static func fetchRecent(in db: Database, limit: Int = 200) throws -> [ClipboardRecord] {
        try ClipboardRecord
            .order(Column("createdAt").desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// FTS5 search with prefix matching on the last token.
    /// Returns items ranked by relevance, or recent items if query is empty.
    static func search(query: String, in db: Database, limit: Int = 200) throws -> [ClipboardRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try fetchRecent(in: db, limit: limit)
        }

        // Build FTS5 query with prefix matching on last token
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var ftsTokens: [String] = []
        for (index, token) in tokens.enumerated() {
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            if index == tokens.count - 1 {
                ftsTokens.append("\"" + escaped + "\"*")
            } else {
                ftsTokens.append("\"" + escaped + "\"")
            }
        }
        let ftsQueryString = ftsTokens.joined(separator: " ")

        let request: SQLRequest<ClipboardRecord> = """
            SELECT clipboardItem.*
            FROM clipboardItem
            JOIN clipboardItemFts ON clipboardItemFts.rowid = clipboardItem.id
            WHERE clipboardItemFts MATCH \(ftsQueryString)
            ORDER BY rank
            LIMIT \(limit)
            """
        return try request.fetchAll(db)
    }

    /// Insert a new record, handling duplicates by deleting the old row first.
    @discardableResult
    static func upsert(_ record: ClipboardRecord, in db: Database) throws -> ClipboardRecord {
        // Delete existing duplicate (moves it to top with fresh createdAt)
        try db.execute(
            sql: "DELETE FROM clipboardItem WHERE contentHash = ?",
            arguments: [record.contentHash]
        )
        var newRecord = record
        try newRecord.insert(db)
        return newRecord
    }

    /// Delete a record by ID.
    static func deleteById(_ id: Int64, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM clipboardItem WHERE id = ?",
            arguments: [id]
        )
    }

    /// Update text content, recalculate hash, and move to top of list.
    static func updatePlainText(id: Int64, newText: String, in db: Database) throws {
        let newHash = sha256(newText.data(using: .utf8)!)

        // Delete any other item with the same hash (dedup)
        try db.execute(
            sql: "DELETE FROM clipboardItem WHERE contentHash = ? AND id != ?",
            arguments: [newHash, id]
        )

        // Update the record in place
        try db.execute(
            sql: """
                UPDATE clipboardItem
                SET plainText = ?, contentHash = ?, createdAt = ?
                WHERE id = ?
                """,
            arguments: [newText, newHash, Date(), id]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Extract frame count and total duration from GIF data using CGImageSource.
    static func gifMetadata(from data: Data) -> (frameCount: Int, duration: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
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

    /// Cleanup: remove items older than retentionDays and enforce maxCount.
    static func cleanup(retentionDays: Int = 30, maxCount: Int = 5000, in db: Database) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

        // Delete by age
        try db.execute(
            sql: "DELETE FROM clipboardItem WHERE createdAt < ?",
            arguments: [cutoff]
        )

        // Delete overflow (keep most recent maxCount)
        try db.execute(
            sql: """
                DELETE FROM clipboardItem
                WHERE id NOT IN (
                    SELECT id FROM clipboardItem
                    ORDER BY createdAt DESC
                    LIMIT ?
                )
                """,
            arguments: [maxCount]
        )
    }
}
