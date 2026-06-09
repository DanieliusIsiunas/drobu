import Foundation
import DrobuShared

/// Accepts incoming XPC connections. The listener-level
/// `setConnectionCodeSigningRequirement` (set in `main`) gates peers against
/// the Apple-anchored Team-ID requirement BEFORE this delegate is consulted; we
/// additionally pin the connection and wire the exported interface. Holds an
/// immutable reference to the shared service, so `@unchecked Sendable` is safe.
final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: SleepControlService

    init(service: SleepControlService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Fail-closed (B1) is established BEFORE this point and does not rely on
        // a return value here: main.swift validates the requirement string parses
        // (SecRequirementCreateWithString) and exits the daemon if it does not,
        // and the listener-level setConnectionCodeSigningRequirement is
        // system-enforced — a non-matching peer is rejected before this delegate
        // runs. The per-connection setCodeSigningRequirement below is
        // defense-in-depth; it is a non-throwing setter (the requirement is
        // already known-parseable), so there is no error path to gate `return`.
        newConnection.exportedInterface = NSXPCInterface(with: DrobuDaemonXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.setCodeSigningRequirement(DaemonConstants.clientCodeSigningRequirement)
        newConnection.resume()
        return true
    }
}
