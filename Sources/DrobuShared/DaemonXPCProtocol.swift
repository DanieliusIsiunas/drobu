import Foundation

/// XPC contract between the Drobu app (client) and `DrobuDaemon` (root).
///
/// NSXPCConnection is callback-based, so every method takes an `@escaping`
/// reply block; the client wraps these in continuations. All parameter and
/// reply types are Sendable-safe primitives (Bool/Int/Double/String) — no
/// non-Sendable type crosses the actor hop (R13, and the AVFoundation/Sendable
/// CI-drift trap in `.claude/rules/media-editing-gotchas.md`).
@objc public protocol DrobuDaemonXPCProtocol {
    /// Enable `pmset disablesleep` for `durationSeconds`. Transactional and
    /// idempotent — re-arms in place if already active. Reply:
    /// `(ok, resultCode, remainingSeconds)` where `resultCode` is a
    /// `DaemonEnableResult` raw value (0 == ok) and `remainingSeconds` is the
    /// authoritative time left for the client to seed caffeinate from.
    func enable(durationSeconds: Int, reply: @escaping (Bool, Int, Double) -> Void)

    /// Disable `pmset disablesleep` and clear persisted state. Reply: `(ok)`.
    func disable(reply: @escaping (Bool) -> Void)

    /// Put displays to sleep now (`pmset displaysleepnow`) — the lid-close
    /// display-off actuator. One-shot; mutates no persistent power setting, so
    /// it never touches session state, the watchdog, or reconciliation. Only
    /// honored while a sleep session is active (refused otherwise — a blank
    /// screen outside a session the user armed is not the daemon's to cause).
    /// Reply: `(ok)`.
    func displayOff(reply: @escaping (Bool) -> Void)

    /// Current session status — the rehydration source after an app relaunch.
    /// Reply: `(active, remainingSeconds)`.
    func status(reply: @escaping (Bool, Double) -> Void)

    /// The protocol version the daemon speaks (compared against the client's
    /// compiled-in `drobuDaemonProtocolVersion`).
    func protocolVersion(reply: @escaping (Int) -> Void)

    /// Human-readable daemon build version, for diagnostics.
    func daemonVersion(reply: @escaping (String) -> Void)
}

/// Result code carried in `enable`'s reply. Lives in DrobuShared so client and
/// daemon interpret the wire integer identically.
public enum DaemonEnableResult: Int, Sendable {
    case ok = 0
    case durationNotAllowed = 1
    case dutyCycleExceeded = 2
    case internalError = 3
}
