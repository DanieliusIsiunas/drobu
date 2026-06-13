import Foundation

/// Pure, injectable removal logic for the daemon's root-owned files, used by the
/// `teardown` XPC selector. Lives in `DrobuShared` (like `Reconciliation` and
/// `RequestValidation`) so it is unit-testable without root and without the
/// daemon executable: tests inject fakes for existence, the safety predicate,
/// and the remove operation; production wires `FileManager` + `FileGuards`.
public enum DaemonTeardown {
    /// Remove each path that both exists and passes `isSafe`. Missing paths are
    /// tolerated (skipped); unsafe paths are refused (never removed) and reported
    /// via `onRefused`. Best-effort: a removal error is reported via `onError`
    /// and does not stop the remaining paths. Returns the paths actually removed.
    ///
    /// The safety predicate is the symlink-refusing, root-ownership check
    /// (`FileGuards.isRootOwnedPrivateRegularFile` in production) — deleting fixed
    /// paths as root in an installer-writable tree without it invites
    /// planted-symlink redirection.
    @discardableResult
    public static func removeFiles(
        _ paths: [String],
        exists: (String) -> Bool,
        isSafe: (String) -> Bool,
        remove: (String) throws -> Void,
        onRefused: (String) -> Void = { _ in },
        onError: (String, Error) -> Void = { _, _ in }
    ) -> [String] {
        var removed: [String] = []
        for path in paths {
            guard exists(path) else { continue }
            guard isSafe(path) else {
                onRefused(path)
                continue
            }
            do {
                try remove(path)
                removed.append(path)
            } catch {
                onError(path, error)
            }
        }
        return removed
    }
}
