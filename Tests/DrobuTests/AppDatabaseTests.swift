import Foundation
import GRDB
import Testing
@testable import DrobuCore

@Suite("AppDatabase.isCorruption")
struct AppDatabaseTests {

    @Test("genuine corruption codes are treated as corruption (→ destructive recreate)")
    func corruptionCodesAreCorruption() {
        #expect(AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        #expect(AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_NOTADB)))
    }

    @Test("transient / environmental SQLite errors are NOT corruption (db must be preserved)")
    func transientErrorsAreNotCorruption() {
        // The data-loss guard: a lock/busy/I-O failure during a relaunch overlap
        // must never trigger the delete-and-recreate path.
        #expect(!AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_BUSY)))
        #expect(!AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_LOCKED)))
        #expect(!AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_IOERR)))
        #expect(!AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_CANTOPEN)))
        #expect(!AppDatabase.isCorruption(DatabaseError(resultCode: .SQLITE_PERM)))
    }

    @Test("a non-DatabaseError is never corruption")
    func nonDatabaseErrorIsNotCorruption() {
        #expect(!AppDatabase.isCorruption(CocoaError(.fileNoSuchFile)))
        #expect(!AppDatabase.isCorruption(NSError(domain: "x", code: 11)))
    }
}
