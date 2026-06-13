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
/// 3 = + teardown (root-state erase for in-app uninstall).
public let drobuDaemonProtocolVersion: Int = 3
