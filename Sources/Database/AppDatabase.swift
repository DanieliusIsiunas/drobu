import GRDB
import Foundation

final class AppDatabase: Sendable {
    let pool: DatabasePool

    init(path: String? = nil) throws {
        let dbPath = path ?? AppDatabase.defaultPath()
        pool = try AppDatabase.openPool(at: dbPath)
        try migrator.migrate(pool)
    }

    private static func openPool(at path: String) throws -> DatabasePool {
        do {
            return try DatabasePool(path: path)
        } catch {
            // Database corruption: delete and recreate
            Log.error("AppDatabase: corruption detected, recreating: \(error)")
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
            return try DatabasePool(path: path)
        }
    }

    private static func defaultPath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("ClipboardHistory", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("clipboard.sqlite").path
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1-createClipboardItems") { db in
            try db.create(table: "clipboardItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("plainText", .text)
                t.column("imageData", .blob)
                t.column("sourceApp", .text)
                t.column("contentHash", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_clipboardItem_contentHash",
                on: "clipboardItem",
                columns: ["contentHash"],
                unique: true
            )

            try db.create(
                index: "idx_clipboardItem_createdAt",
                on: "clipboardItem",
                columns: ["createdAt"]
            )

            try db.create(virtualTable: "clipboardItemFts", using: FTS5()) { t in
                t.synchronize(withTable: "clipboardItem")
                t.tokenizer = .unicode61()
                t.column("plainText")
            }
        }

        migrator.registerMigration("v2-addSourceBundleId") { db in
            try db.alter(table: "clipboardItem") { t in
                t.add(column: "sourceBundleId", .text)
            }
        }

        return migrator
    }

    func deleteAll() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM clipboardItem")
        }
    }
}
