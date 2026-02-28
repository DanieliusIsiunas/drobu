import Foundation

enum PrivilegedCommandError: Error {
    case scriptCreationFailed
    case userCancelled
    case executionFailed(code: Int, message: String)
}

/// Runs a shell command with admin privileges via the macOS auth dialog.
/// Batch multiple commands with && for a single auth prompt.
@MainActor
func runPrivileged(_ command: String) throws -> String {
    let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
    let source = "do shell script '\(escaped)' with administrator privileges"

    guard let script = NSAppleScript(source: source) else {
        throw PrivilegedCommandError.scriptCreationFailed
    }

    var errorDict: NSDictionary?
    let result = script.executeAndReturnError(&errorDict)

    if let error = errorDict {
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
        if code == -128 { throw PrivilegedCommandError.userCancelled }
        throw PrivilegedCommandError.executionFailed(code: code, message: message)
    }
    return result.stringValue ?? ""
}
