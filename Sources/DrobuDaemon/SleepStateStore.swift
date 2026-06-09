import Foundation
import DrobuShared

/// Persists `SleepSessionState` to a root-owned 0600 file in a root-owned 0700
/// directory, created under `umask(0o077)`. Trusted only after verification on
/// read: a file that is not a root-owned private regular file, or whose parent
/// dir is not root-owned / is group-or-other-writable, is treated as untrusted
/// → returns nil so the reconciliation table reverses any orphaned state rather
/// than adopting a tampered deadline. (The deadline-ceiling tamper check lives
/// in `SleepSessionState.isDeadlineTrustworthy`, applied by the caller.)
enum SleepStateStore {
    /// Ensure the support dir exists as root:wheel 0700.
    static func ensureSupportDirectory() {
        let path = DaemonConstants.supportDirectory
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } else {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    static func write(_ state: SleepSessionState) {
        ensureSupportDirectory()
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        do {
            let data = try SleepSessionStateCodec.encode(state)
            try data.write(to: URL(fileURLWithPath: DaemonConstants.stateFilePath), options: [.atomic])
            // .atomic renames a temp into place; re-assert 0600 explicitly.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: DaemonConstants.stateFilePath)
        } catch {
            DaemonLog.write("SleepStateStore: write failed: \(error)")
        }
    }

    /// Read + verify. Returns nil when absent, untrusted, or corrupt.
    static func read() -> SleepSessionState? {
        let path = DaemonConstants.stateFilePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard FileGuards.isRootOwnedSafeDirectory(DaemonConstants.supportDirectory) else {
            DaemonLog.write("SleepStateStore: support dir failed ownership/mode check — ignoring state")
            return nil
        }
        guard FileGuards.isRootOwnedPrivateRegularFile(path) else {
            DaemonLog.write("SleepStateStore: state file failed ownership/mode check — ignoring state")
            return nil
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try SleepSessionStateCodec.decode(data)
        } catch {
            DaemonLog.write("SleepStateStore: state file corrupt/unreadable — ignoring: \(error)")
            return nil
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: DaemonConstants.stateFilePath)
    }
}
