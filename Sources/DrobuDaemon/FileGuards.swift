import Foundation

/// `lstat`-based, symlink-refusing file/dir safety checks for the root daemon.
/// Reading or deleting fixed paths as root in an installer-writable tree invites
/// planted-symlink redirection (the legacy-sweep and state-file TOCTOU hazards);
/// these are the shared primitive that refuses to follow symlinks and verifies
/// ownership/mode before the daemon trusts a path. `st_mode` and the `S_IF*`
/// constants are `mode_t` here, so the masks stay in that type.
enum FileGuards {
    /// A regular file owned by root with NO group/other permission bits.
    static func isRootOwnedPrivateRegularFile(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }    // regular file (not symlink/dir)
        guard st.st_uid == 0 else { return false }                      // root-owned
        guard (st.st_mode & (S_IRWXG | S_IRWXO)) == 0 else { return false } // no group/other access
        return true
    }

    /// A regular file (not a symlink or directory). Legacy artifacts were
    /// created 0644/0440, so the sweep requires only regular-file + a safe
    /// parent dir — not 0600.
    static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    /// A directory owned by root and not group/other-writable.
    static func isRootOwnedSafeDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard st.st_uid == 0 else { return false }
        guard (st.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
        return true
    }
}
