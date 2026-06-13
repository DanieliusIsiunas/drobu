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

        // Rotate: if current log > 2MB, move to .1 (overwrite previous)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 2_000_000 {
            try? FileManager.default.removeItem(at: prevURL)
            try? FileManager.default.moveItem(at: url, to: prevURL)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        let fh = try? FileHandle(forWritingTo: url)
        fh?.seekToEndOfFile()
        return fh
    }()

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
