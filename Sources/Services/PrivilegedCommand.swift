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
    let tmpDir = NSTemporaryDirectory()
    let scriptPath = "\(tmpDir)cliphistory-priv-\(pid).sh"
    let askpassPath = "\(tmpDir)cliphistory-askpass-\(pid).sh"

    // Write the command script atomically with restricted permissions
    do {
        guard let scriptData = command.data(using: .utf8) else {
            throw PrivilegedCommandError.scriptCreationFailed
        }
        guard FileManager.default.createFile(atPath: scriptPath, contents: scriptData,
                                             attributes: [.posixPermissions: 0o700]) else {
            throw PrivilegedCommandError.scriptCreationFailed
        }
    } catch let error as PrivilegedCommandError {
        throw error
    } catch {
        throw PrivilegedCommandError.scriptCreationFailed
    }

    // Write the askpass script — osascript shows a password dialog, prints to stdout
    let askpassContent = """
        #!/bin/sh
        /usr/bin/osascript <<'APPLESCRIPT'
        text returned of (display dialog "Drobu needs administrator access to prevent sleep with the lid closed." with title "Administrator Access" with icon caution with hidden answer default answer "" buttons {"Cancel", "OK"} default button "OK")
        APPLESCRIPT
        """
    do {
        guard let askpassData = askpassContent.data(using: .utf8) else {
            throw PrivilegedCommandError.scriptCreationFailed
        }
        guard FileManager.default.createFile(atPath: askpassPath, contents: askpassData,
                                             attributes: [.posixPermissions: 0o700]) else {
            throw PrivilegedCommandError.scriptCreationFailed
        }
    } catch let error as PrivilegedCommandError {
        do { try FileManager.default.removeItem(atPath: scriptPath) }
        catch let cleanupErr { Log.debug("PrivilegedCommand: cleanup script failed: \(cleanupErr)") }
        throw error
    } catch {
        do { try FileManager.default.removeItem(atPath: scriptPath) }
        catch let cleanupErr { Log.debug("PrivilegedCommand: cleanup script failed: \(cleanupErr)") }
        throw PrivilegedCommandError.scriptCreationFailed
    }

    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                do { try FileManager.default.removeItem(atPath: scriptPath) }
                catch let cleanupErr { Log.debug("PrivilegedCommand: cleanup script failed: \(cleanupErr)") }
                do { try FileManager.default.removeItem(atPath: askpassPath) }
                catch let cleanupErr { Log.debug("PrivilegedCommand: cleanup askpass failed: \(cleanupErr)") }
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
