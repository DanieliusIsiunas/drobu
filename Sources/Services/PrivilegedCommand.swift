import Foundation

enum PrivilegedCommandError: Error {
    case scriptCreationFailed
    case userCancelled
    case executionFailed(code: Int, message: String)
}

/// Runs a shell command with admin privileges via `sudo -A` with a custom askpass dialog.
///
/// Bypasses the macOS Authorization framework entirely (which has a regression on macOS 26.3
/// returning `-60008`). Instead uses:
/// 1. `display dialog` (AppKit) for the password prompt
/// 2. `sudo -A` + PAM (`/etc/pam.d/sudo`) for privilege escalation
func runPrivileged(_ command: String) async throws -> String {
    let pid = ProcessInfo.processInfo.processIdentifier
    let scriptPath = "/tmp/cliphistory-priv-\(pid).sh"
    let askpassPath = "/tmp/cliphistory-askpass-\(pid).sh"

    // Write the command script
    do {
        try command.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    } catch {
        throw PrivilegedCommandError.scriptCreationFailed
    }

    // Write the askpass script — osascript shows a password dialog, prints to stdout
    let askpassContent = """
        #!/bin/sh
        /usr/bin/osascript <<'APPLESCRIPT'
        text returned of (display dialog "ClipboardHistory needs administrator access to prevent sleep with the lid closed." with title "Administrator Access" with icon caution with hidden answer default answer "" buttons {"Cancel", "OK"} default button "OK")
        APPLESCRIPT
        """
    do {
        try askpassContent.write(toFile: askpassPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: askpassPath)
    } catch {
        try? FileManager.default.removeItem(atPath: scriptPath)
        throw PrivilegedCommandError.scriptCreationFailed
    }

    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? FileManager.default.removeItem(atPath: scriptPath)
                try? FileManager.default.removeItem(atPath: askpassPath)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["-A", "/bin/sh", scriptPath]
            proc.environment = [
                "SUDO_ASKPASS": askpassPath,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            proc.standardInput = FileHandle.nullDevice

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: PrivilegedCommandError.executionFailed(
                    code: -1, message: "Failed to launch sudo: \(error)"))
                return
            }

            proc.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus == 0 {
                continuation.resume(returning: stdout)
                return
            }

            // User cancelled the askpass dialog (osascript returns -128)
            if stderr.contains("-128") || stderr.contains("User canceled") {
                continuation.resume(throwing: PrivilegedCommandError.userCancelled)
                return
            }

            // Wrong password or sudo refused auth
            if proc.terminationStatus == 1 && stderr.lowercased().contains("password") {
                continuation.resume(throwing: PrivilegedCommandError.userCancelled)
                return
            }

            continuation.resume(throwing: PrivilegedCommandError.executionFailed(
                code: Int(proc.terminationStatus),
                message: stderr.isEmpty ? "sudo exited \(proc.terminationStatus)" : stderr))
        }
    }
}
