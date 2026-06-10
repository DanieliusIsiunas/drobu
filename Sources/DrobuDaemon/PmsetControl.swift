import Foundation
import DrobuShared

/// Wraps the real `pmset` calls. The daemon IS root, so no sudo is involved.
/// Not unit-tested (R12 — real pmset is out of unit scope); the parsing it
/// relies on (`parseSleepDisabled`) is tested in DrobuShared.
enum PmsetControl {
    /// `pmset disablesleep 1|0`. Returns true on exit 0.
    @discardableResult
    static func setDisableSleep(_ disabled: Bool) -> Bool {
        runPmset(["disablesleep", disabled ? "1" : "0"])
    }

    /// `pmset displaysleepnow` — immediate display sleep, the lid-close
    /// display-off actuator. One-shot (no persistent setting changes; the lid
    /// or HID wake relights the panel). Returns true on exit 0.
    @discardableResult
    static func displaySleepNow() -> Bool {
        runPmset(["displaysleepnow"])
    }

    /// Run a no-output `pmset` mutation; true on exit 0.
    private static func runPmset(_ arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            DaemonLog.write("PmsetControl: pmset \(arguments.first ?? "?") run failed: \(error)")
            return false
        }
    }

    /// Read `pmset -g` and parse the `SleepDisabled` flag via the M1 parser.
    static func isSleepDisabled() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // Read before waitUntilExit to avoid a pipe-buffer deadlock.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return parseSleepDisabled(fromPmsetG: String(decoding: data, as: UTF8.self))
        } catch {
            DaemonLog.write("PmsetControl: pmset -g read failed: \(error)")
            return false
        }
    }
}
