import Foundation

enum Log {
    static let debugEnabled = true

    private static let queue = DispatchQueue(label: "com.clipboardhistory.log", qos: .utility)

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("ClipboardHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        let fh = try? FileHandle(forWritingTo: url)
        fh?.truncateFile(atOffset: 0)
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
