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
        newConnection.exportedInterface = NSXPCInterface(with: DrobuDaemonXPCProtocol.self)
        newConnection.exportedObject = service
        // Defense in depth alongside the listener-level requirement.
        newConnection.setCodeSigningRequirement(DaemonConstants.clientCodeSigningRequirement)
        newConnection.resume()
        return true
    }
}
