import GRDB
import Foundation

final class AppDatabase: Sendable {
    let pool: DatabasePool

    init(path: String? = nil) throws {
        let dbPath = try path ?? AppDatabase.defaultPath()
        pool = try AppDatabase.openPool(at: dbPath)
        try migrator.migrate(pool)
    }

    private static func openPool(at path: String) throws -> DatabasePool {
        do {
            return try DatabasePool(path: path)
        } catch {
            // Database corruption: delete and recreate
            Log.error("AppDatabase: corruption detected, recreating: \(error)")
            do { try FileManager.default.removeItem(atPath: path) }
            catch { Log.error("AppDatabase: failed to remove corrupt db: \(error)") }
            do { try FileManager.default.removeItem(atPath: path + "-wal") }
            catch { Log.error("AppDatabase: failed to remove wal: \(error)") }
            do { try FileManager.default.removeItem(atPath: path + "-shm") }
            catch { Log.error("AppDatabase: failed to remove shm: \(error)") }
            return try DatabasePool(path: path)
        }
    }

    private static func defaultPath() throws -> String {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Application Support directory not found"
            ])
        }
        let appSupport = base.appendingPathComponent("ClipboardHistory", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Ensure permissions are tightened on pre-existing directories from older versions
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)
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
