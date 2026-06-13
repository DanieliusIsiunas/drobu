import AppKit
import Foundation
import DrobuShared

/// Moves the app bundle to the Trash after the app quits. A running app cannot
/// trash its own in-use bundle (the original drag-to-Trash bug), so this spawns
/// a detached `/bin/sh` waiter that outlives the app, confirms the app process
/// and the daemon are gone, re-verifies the bundle wasn't swapped by a Sparkle
/// update, then moves it to the Trash (recoverable) via Finder.
///
/// System boundary (process spawn + Finder Automation): excluded from unit tests
/// per the XPC-wire convention; verified manually.
protocol BundleTrashing: Sendable {
    func scheduleTrash(bundleURL: URL)
}

struct BundleTrasher: BundleTrashing {
    func scheduleTrash(bundleURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let expectedVersion = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""

        // The bundle path and pid are passed as POSITIONAL ARGUMENTS ($1…$4),
        // never interpolated into the script body — so a hostile path cannot
        // inject shell. The script body is a fixed literal.
        //   $1 app pid   $2 daemon process name   $3 expected CFBundleVersion   $4 bundle path
        let script = """
        i=0; while kill -0 "$1" 2>/dev/null; do [ $i -ge 100 ] && { /usr/bin/logger "Drobu uninstall: app still running after timeout — bundle left in place"; exit 0; }; sleep 0.1; i=$((i+1)); done
        i=0; while pgrep -qx "$2"; do [ $i -ge 100 ] && { /usr/bin/logger "Drobu uninstall: daemon still running after timeout — bundle left in place"; exit 0; }; sleep 0.1; i=$((i+1)); done
        ver=$(/usr/bin/defaults read "$4/Contents/Info" CFBundleVersion 2>/dev/null)
        [ "$ver" = "$3" ] || exit 0
        /usr/bin/osascript -e 'on run argv' -e 'tell application "Finder" to delete (POSIX file (item 1 of argv))' -e 'end run' "$4"
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "sh",
                          "\(pid)",
                          DaemonProcessName.value,
                          expectedVersion,
                          bundleURL.path]
        do {
            try proc.run()
            Log.info("BundleTrasher: detached self-delete scheduled for \(bundleURL.lastPathComponent)")
        } catch {
            Log.error("BundleTrasher: failed to spawn self-delete helper: \(error)")
        }
    }
}

/// The daemon executable's process name, derived from its bundle-program path so
/// the trasher waits for the right process to exit before removing the bundle.
private enum DaemonProcessName {
    static let value = (DaemonConstants.bundleProgramPath as NSString).lastPathComponent
}
