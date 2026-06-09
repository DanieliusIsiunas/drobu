import Foundation

/// Constants shared between the Drobu app (XPC client) and the privileged
/// `DrobuDaemon`. Lives in `DrobuShared` so the daemon executable and
/// `DrobuCore` reference identical values — drift between the launchd plist,
/// the Mach-service name, and the code-sign requirement is exactly the failure
/// mode these constants exist to prevent (the `DaemonConstantsTests` drift
/// suite pins the plist against them).
public enum DaemonConstants {
    /// launchd `Label`, Mach-service name, and the daemon's code-sign
    /// `--identifier`. Intentionally distinct from the app's bundle id
    /// (`com.danielius.ClipboardHistory`) so the daemon does NOT satisfy its
    /// own client requirement (review finding M3).
    public static let daemonLabel = "com.danielius.ClipboardHistory.daemon"

    /// The Mach service the client looks up — same string as the label.
    public static let machServiceName = daemonLabel

    /// Filename passed to `SMAppService.daemon(plistName:)`; the signed bundle
    /// carries it at `Contents/Library/LaunchDaemons/`.
    public static let plistName = "com.danielius.ClipboardHistory.daemon.plist"

    /// The path `BundleProgram` points at, relative to the app bundle.
    public static let bundleProgramPath = "Contents/MacOS/DrobuDaemon"

    /// The app's bundle identifier — what the daemon pins incoming XPC peers to.
    public static let appBundleIdentifier = "com.danielius.ClipboardHistory"

    /// Developer ID Team ID (Apple-issued, stable across rebuilds).
    public static let teamIdentifier = "TGL69S88MD"

    /// Code-sign requirement the daemon's listener pins for incoming XPC
    /// connections. Apple-anchored Team-ID form: unforgeable (the Apple CA
    /// chain cannot be minted locally) and stable across every rebuild (Team ID
    /// + identifier do not change). NEVER a cdhash (per-build drift) and never
    /// an unanchored CN/OU match (spoofable). This hand-written Team-ID form is
    /// the pinned control — intentionally narrower and more stable than the
    /// auto-generated designated requirement. U7's negative-path test proves it
    /// actually engages; `codesign -d -r-` on the signed app confirms the match.
    public static let clientCodeSigningRequirement =
        "anchor apple generic and identifier \"\(appBundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Code-sign requirement the *client* pins on its connection to verify the
    /// *daemon* it is talking to. Pins the DAEMON's identifier — which is
    /// distinct from the app's (M3) — so the client accepts only the genuine
    /// Developer-ID daemon. The two directions pin DIFFERENT identities: the
    /// daemon's listener uses `clientCodeSigningRequirement` (the app id) to
    /// verify the client; the client uses this to verify the daemon. Using the
    /// app requirement here would reject the real daemon (its id is `.daemon`).
    public static let daemonCodeSigningRequirement =
        "anchor apple generic and identifier \"\(daemonLabel)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    // MARK: - Daemon-owned paths (root:wheel)

    /// Root-owned support directory (mode 0700, created under `umask(0o077)`).
    /// Distinct from the *client's* `~/Library/Application Support/ClipboardHistory`
    /// — this one is under the system `/Library` and is the daemon's alone.
    public static let supportDirectory = "/Library/Application Support/ClipboardHistory"

    /// Persisted session state (absolute deadline + duty-cycle accumulator). 0600.
    public static let stateFilePath = supportDirectory + "/daemon-session.json"

    /// Daemon log. A root daemon has no home dir, so it cannot reuse `Log`
    /// (which writes under `~/Library/...`). 0600.
    public static let logFilePath = supportDirectory + "/daemon.log"

    // MARK: - Legacy artifacts (swept on first daemon start; R9)

    /// The pre-daemon transient LaunchDaemon plist.
    public static let legacyDaemonPlistPath =
        "/Library/LaunchDaemons/com.clipboardhistory.disablesleep-reversal.plist"

    /// The pre-daemon cleanup script.
    public static let legacyCleanupScriptPath =
        supportDirectory + "/cleanup-disablesleep.sh"

    /// The pre-daemon NOPASSWD sudoers entry — the standing local-root
    /// primitive; removed FIRST in any cleanup ordering.
    public static let legacySudoersPath = "/etc/sudoers.d/clipboardhistory-cleanup"

    /// The loaded launchd label to `bootout` from the system domain.
    public static let legacyLaunchdLabel = "com.clipboardhistory.disablesleep-reversal"

    /// The three legacy *file* artifacts, sudoers FIRST (it is the standing
    /// root primitive and must be deleted before the rest). The fourth
    /// documented artifact — `legacyLaunchdLabel` — is a `launchctl bootout`
    /// target, not a file, so it is handled separately by the sweep.
    public static let legacyArtifactPaths = [
        legacySudoersPath,
        legacyCleanupScriptPath,
        legacyDaemonPlistPath,
    ]
}
