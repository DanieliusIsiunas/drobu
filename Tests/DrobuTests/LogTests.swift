import Foundation
import Testing
@testable import DrobuCore

@Suite("Log test-isolation")
struct LogTests {
    /// Pins the guard that keeps test runs out of the production app.log. If a
    /// future toolchain stops setting every XCTest-harness signal this relies
    /// on, this assertion fails loudly here rather than silently resuming
    /// pollution of the user's real log. (It is also the empirical proof the
    /// detection fires under `swift test`.)
    @Test("Log detects the test runtime and suppresses production-log writes")
    func detectsTestRuntime() {
        #expect(Log.isRunningInTests)
    }

    /// Logging from within tests must not create or touch the production
    /// app.log. Emitting all three levels here would, without the guard, append
    /// fixture lines to the shared file.
    @Test("logging under tests does not write the production app.log")
    func loggingDoesNotTouchProductionLog() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return  // no Application Support (CI sandbox) — nothing to pollute
        }
        let logURL = base.appendingPathComponent("ClipboardHistory/app.log")
        let before = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.modificationDate] as? Date

        Log.info("LogTests: this line must never reach the production log")
        Log.error("LogTests: nor this one")
        Log.debug("LogTests: nor this")

        let after = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.modificationDate] as? Date
        #expect(before == after)  // mtime unchanged (and nil == nil if the file doesn't exist)
    }

    /// On launch the current log is moved to app.log.1 (one prior session kept)
    /// so each session starts fresh — the rotation that prevents stale content
    /// (including any pre-guard test-fixture leakage) from accumulating forever.
    @Test("rotateForNewSession moves the current log to the backup and starts fresh")
    func rotatesLogForNewSession() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drobu-log-rotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("app.log")
        let previous = dir.appendingPathComponent("app.log.1")
        try "current session\n".write(to: current, atomically: true, encoding: .utf8)
        try "older backup to be overwritten\n".write(to: previous, atomically: true, encoding: .utf8)

        Log.rotateForNewSession(current: current, previous: previous, fileManager: .default)

        #expect(!FileManager.default.fileExists(atPath: current.path))   // moved away → next session starts empty
        #expect(try String(contentsOf: previous, encoding: .utf8) == "current session\n")  // prior session kept, old backup gone
    }

    @Test("rotateForNewSession is a no-op when there is no current log")
    func rotateForNewSessionNoCurrent() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drobu-log-rotate-\(UUID().uuidString)")
        let current = dir.appendingPathComponent("app.log")     // never created
        let previous = dir.appendingPathComponent("app.log.1")
        Log.rotateForNewSession(current: current, previous: previous, fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: previous.path))  // nothing fabricated
    }
}
