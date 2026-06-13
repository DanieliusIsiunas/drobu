import Foundation

enum Log {
    #if DEBUG
    static let debugEnabled = true
    #else
    static let debugEnabled = false
    #endif

    private static let queue = DispatchQueue(label: "com.clipboardhistory.log", qos: .utility)

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// True when running inside the test bundle. Tests construct real services
    /// (e.g. ClosedLidService) that log through this type; without this guard
    /// those writes land in the SHARED production `app.log`, interleaving
    /// fixture artifacts (StubError, 2001-dated deadlines, deliberately-exercised
    /// failure paths) with real session history and corrupting on-machine
    /// debugging. Detected via the XCTest-harness signals SwiftPM sets for
    /// `swift test` (Swift Testing still runs inside the .xctest bundle).
    static let isRunningInTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        // Xcode / XCTest-based runs set these.
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return true
        }
        // SwiftPM `swift test` (incl. Swift Testing) sets NONE of the above —
        // it runs the bundle inside `swiftpm-testing-helper` (verified on this
        // toolchain) or the `xctest` tool. Match the host process instead.
        let proc = ProcessInfo.processInfo.processName
        if proc == "swiftpm-testing-helper" || proc == "xctest" { return true }
        let arg0 = ProcessInfo.processInfo.arguments.first ?? ""
        return arg0.contains("swiftpm-testing-helper")
            || arg0.hasSuffix("/xctest")
            || arg0.contains(".xctest/")
    }()

    private static let fileHandle: FileHandle? = {
        // Never write the production log from a test run.
        if isRunningInTests { return nil }
        guard let dir = AppPaths.appSupportDirectory else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        let prevURL = dir.appendingPathComponent("app.log.1")

        // Start each session with a fresh log (the documented behavior: the log
        // "only contains the current session"). The prior session is moved to
        // app.log.1 so a post-crash investigation can still read it. This is what
        // keeps stale content — including any fixture lines a pre-guard
        // `swift test` once leaked — from accumulating across launches.
        rotateForNewSession(current: url, previous: prevURL, fileManager: .default)

        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        return try? FileHandle(forWritingTo: url)
    }()

    /// Rotate the log for a new session: if a current log exists, move it to
    /// `previous` (overwriting the older backup) so the new session starts empty
    /// and exactly one prior session is retained. Pure + injectable so the
    /// rotation is unit-testable without the production singleton.
    static func rotateForNewSession(current: URL, previous: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: current.path) else { return }
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: current, to: previous)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        write("DEBUG \(message())")
    }

    static func info(_ message: @autoclosure () -> String)  { write("INFO  \(message())") }
    static func error(_ message: @autoclosure () -> String) { write("ERROR \(message())") }

    private static func write(_ message: String) {
        let line = "\(df.string(from: Date())) \(message)\n"
        queue.async { fileHandle?.write(Data(line.utf8)) }
    }
}
