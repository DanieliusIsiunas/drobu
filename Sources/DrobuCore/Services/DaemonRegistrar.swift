import Foundation
import ServiceManagement
import DrobuShared

/// Mapped daemon registration status — a stable surface over
/// `SMAppService.Status` that the UI and tests switch on.
public enum DaemonStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    /// A registration/unregistration error (description kept as a String so the
    /// enum stays Equatable/Sendable).
    case failed(String)
}

/// Injectable seam over `SMAppService.daemon(plistName:)` so the registrar's
/// status mapping and state-correct remediation are unit-testable without
/// touching the real Background Task Management database. `@MainActor` because
/// it is driven entirely from the Settings UI.
@MainActor
public protocol DaemonServiceControlling: AnyObject {
    var rawStatus: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

/// Production control backed by the real `SMAppService.daemon`.
@MainActor
public final class SMAppServiceDaemonControl: DaemonServiceControlling {
    private let service: SMAppService

    public init(plistName: String = DaemonConstants.plistName) {
        self.service = SMAppService.daemon(plistName: plistName)
    }

    public var rawStatus: SMAppService.Status { service.status }
    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The slice of registration `ClosedLidService` needs — injectable so the
/// service's status-gating is testable without `SMAppService`.
@MainActor
public protocol DaemonRegistration: AnyObject {
    var status: DaemonStatus { get }
    @discardableResult func register() -> DaemonStatus
}

/// Wraps daemon registration: status mapping, `register`/`unregister`, the
/// Login Items deep-link, and — crucially — *state-correct* remediation (R3),
/// so the user is never sent to a toggle that does not exist yet.
@MainActor
public final class DaemonRegistrar: DaemonRegistration {
    private let control: DaemonServiceControlling

    public init(control: DaemonServiceControlling = SMAppServiceDaemonControl()) {
        self.control = control
    }

    public var status: DaemonStatus { Self.map(control.rawStatus) }

    static func map(_ status: SMAppService.Status) -> DaemonStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .failed("unknown SMAppService status (\(status.rawValue))")
        }
    }

    /// Register the daemon. Returns the resulting mapped status, or `.failed`.
    @discardableResult
    public func register() -> DaemonStatus {
        do {
            try control.register()
            let result = status
            Log.info("DaemonRegistrar: register() → \(result)")
            return result
        } catch {
            // Surface the real SMAppService error — registration failures are
            // otherwise invisible (the client just shows generic guidance).
            Log.error("DaemonRegistrar: register() failed: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    /// Unregister — orphan recovery for a stale BTM binding.
    @discardableResult
    public func unregister() -> DaemonStatus {
        do {
            try control.unregister()
            return status
        } catch {
            Log.error("DaemonRegistrar: unregister() failed: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    public func openApprovalSettings() {
        control.openSettings()
    }

    /// State-correct remediation (R3). The user never lands on a toggle that
    /// does not exist yet:
    ///  - `.notRegistered` → `register()` inline (which *creates* the approval
    ///    toggle); only if the result is `.requiresApproval` do we deep-link.
    ///  - `.requiresApproval` / `.notFound` → deep-link straight to Login Items.
    ///  - `.enabled` → nothing to do.
    /// Returns the status after the remediation attempt.
    @discardableResult
    public func remediate() -> DaemonStatus {
        switch status {
        case .notRegistered:
            let after = register()
            if after == .requiresApproval { openApprovalSettings() }
            return after
        case .requiresApproval, .notFound:
            openApprovalSettings()
            return status
        case .enabled, .failed:
            return status
        }
    }
}
