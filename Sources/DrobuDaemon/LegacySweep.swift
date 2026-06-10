import Foundation
import DrobuShared

/// Removes the four pre-daemon artifacts on first daemon start (R9). Idempotent
/// — a second run no-ops. Ordering matters: the NOPASSWD sudoers entry (the
/// standing local-root primitive) is deleted FIRST. Every file path is
/// `lstat`-checked (refuses symlinks; never follows a planted redirect) and its
/// parent dir verified root-owned + not group/other-writable before unlinking.
/// Never `rm -rf`.
enum LegacySweep {
    static func run() {
        // 1. sudoers entry first — it is the standing local-root primitive.
        removeFileIfSafe(DaemonConstants.legacySudoersPath)
        // 2. boot out the loaded launchd job (best-effort).
        bootOutLegacyLaunchd()
        // 3. the remaining artifacts.
        removeFileIfSafe(DaemonConstants.legacyCleanupScriptPath)
        removeFileIfSafe(DaemonConstants.legacyDaemonPlistPath)
    }

    private static func removeFileIfSafe(_ path: String) {
        // Absent → nothing to do (keeps the sweep idempotent).
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard FileGuards.isRegularFile(path) else {
            DaemonLog.write("LegacySweep: refusing non-regular file at a legacy path")
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard FileGuards.isRootOwnedSafeDirectory(parent) else {
            DaemonLog.write("LegacySweep: refusing — legacy path parent dir failed ownership/mode check")
            return
        }
        if unlink(path) != 0 {
            DaemonLog.write("LegacySweep: unlink failed (errno \(errno))")
        }
    }

    private static func bootOutLegacyLaunchd() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "system/\(DaemonConstants.legacyLaunchdLabel)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            DaemonLog.write("LegacySweep: launchctl bootout failed: \(error)")
        }
    }
}
