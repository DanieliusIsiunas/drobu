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
}
