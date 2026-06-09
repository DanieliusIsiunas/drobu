import Foundation
import DrobuShared

// Restrictive umask so anything the daemon creates (state file, log) is
// owner-only (0600). Per .claude/rules/file-permission-hardening.md.
umask(0o077)

// B1 (fail closed): a code-sign requirement string that does not parse is
// identical to NO gate against a root daemon. Validate it BEFORE listening and
// refuse to start if it is unparseable, rather than accept unvalidated peers.
guard isParseableCodeSigningRequirement(DaemonConstants.clientCodeSigningRequirement) else {
    FileHandle.standardError.write(Data(
        "\(DaemonConstants.daemonLabel): code-sign requirement failed to parse — refusing to start\n".utf8))
    exit(1)
}

let service = SleepControlService()
// Legacy sweep + boot reconciliation before accepting any connection, so an
// orphaned/expired/untrusted session is resolved at launch (R7/R9/R14).
service.startUp()

let delegate = DaemonListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: DaemonConstants.machServiceName)
listener.delegate = delegate
// System-enforced peer gate (Apple-anchored Team-ID requirement) applied to
// every incoming connection before the delegate is consulted.
listener.setConnectionCodeSigningRequirement(DaemonConstants.clientCodeSigningRequirement)
listener.resume()

DaemonLog.write("\(DaemonConstants.daemonLabel): listening (pid \(ProcessInfo.processInfo.processIdentifier))")
dispatchMain()
