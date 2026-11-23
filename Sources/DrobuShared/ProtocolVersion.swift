import Foundation

/// Version of the `DrobuDaemon` XPC protocol wire shape. Bump whenever the
/// protocol's method signatures or persisted-state semantics change.
///
/// The client compares its compiled-in `drobuDaemonProtocolVersion` against the
/// value the daemon reports on connect. A mismatch (a stale daemon left behind
/// after a Sparkle update) refuses activation and attempts `register()` to
/// install the bundled daemon — the client never speaks a newer protocol at an
/// older daemon.
///
/// History: 1 = initial (enable/disable/status/versions); 2 = + displayOff;
/// 3 = + teardown (root-state erase for in-app uninstall); 4 = 8h sessions
/// (max duration 4h → 8h, duty-cycle cap 8h → 16h per 24h). No wire change, but
/// a pre-4 daemon still running after an update would refuse 8h as
/// `durationNotAllowed` — the bump makes the client bounce it; 5 = 10h sessions
/// replace 8h (max duration 8h → 10h, duty-cycle cap 16h → 20h per 24h), bumped
/// for the same reason: a pre-5 daemon would refuse 10h.
public let drobuDaemonProtocolVersion: Int = 5
