// U7 negative-path test: an AD-HOC-SIGNED client (this binary) must be REFUSED
// by DrobuDaemon's XPC listener, whose setConnectionCodeSigningRequirement pins
// the Drobu app identity (Team TGL69S88MD). A reply here = security failure.
//
// RESULT (2026-06-10, M4 Pro / macOS 26.3.1, pre-v1.5 release): **PASS** —
//   compiled via `swiftc` (Signature=adhoc, TeamIdentifier=not set), run against
//   the live daemon (pid 86443): connection INTERRUPTED, error handler fired
//   (NSCocoaErrorDomain 4097), no reply within 5s. Positive control: the same
//   daemon process served the genuine Drobu client minutes earlier (live
//   Closed Lid session). The code-sign boundary engages.
//
// Re-run after any signing/requirement change:
//   swiftc -o /tmp/xpc-neg-test tools/spikes/xpc-negative-path-test.swift && /tmp/xpc-neg-test
import Foundation

@objc protocol DrobuDaemonXPCProtocol {
    func protocolVersion(reply: @escaping (Int) -> Void)
}

let conn = NSXPCConnection(machServiceName: "com.danielius.ClipboardHistory.daemon", options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: DrobuDaemonXPCProtocol.self)
conn.invalidationHandler = { print("event: connection INVALIDATED") }
conn.interruptionHandler = { print("event: connection INTERRUPTED") }
conn.resume()

let sem = DispatchSemaphore(value: 0)
var gotReply = false

let proxy = conn.remoteObjectProxyWithErrorHandler { error in
    print("event: XPC error handler fired: \((error as NSError).domain) code \((error as NSError).code)")
    sem.signal()
} as? DrobuDaemonXPCProtocol

proxy?.protocolVersion { version in
    gotReply = true
    print("event: GOT REPLY protocolVersion=\(version)")
    sem.signal()
}

_ = sem.wait(timeout: .now() + 5)
if gotReply {
    print("RESULT: FAIL — the daemon ANSWERED an ad-hoc-signed client (code-sign requirement not enforced)")
    exit(1)
} else {
    print("RESULT: PASS — the daemon refused the unauthorized client (no reply within 5s)")
    exit(0)
}
