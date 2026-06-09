import Foundation
import DrobuShared

/// Root-daemon logger. A root daemon has no home dir, so it cannot reuse `Log`
/// (which writes under `~/Library/...`); it writes to a root-owned 0600 file.
///
/// Sanitization: callers pass only numeric/enum-derived values, never raw
/// XPC-parameter strings — durations are `Int`, results are enum raw values —
/// so there is no path for ANSI-escape / newline log injection from a peer
/// (review watch item).
enum DaemonLog {
    private static let queue = DispatchQueue(label: "com.danielius.ClipboardHistory.daemon.log")

    static func write(_ message: String) {
        let timestamp = Date()
        queue.async {
            let formatter = ISO8601DateFormatter()
            let line = "[\(formatter.string(from: timestamp))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let path = DaemonConstants.logFilePath
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // umask is 0o077 process-wide; pin 0600 explicitly too.
                _ = FileManager.default.createFile(
                    atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
