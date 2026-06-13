import Foundation
import ServiceManagement

/// Injectable seam over `SMAppService.mainApp` (launch-at-login). `SMAppService`
/// has no mockable surface, so this protocol lets the launch-at-login toggle and
/// the uninstall flow share one testable path. Mirrors `DaemonServiceControlling`.
@MainActor
protocol LaunchAgentControlling: AnyObject {
    /// True only when the login item is actively enabled — drives the toggle's
    /// on/off display.
    var isEnabled: Bool { get }
    /// True when a registration record EXISTS (`.enabled` OR `.requiresApproval`)
    /// — i.e. there is something for uninstall to remove. A `.requiresApproval`
    /// item is not enabled but still shows in Login Items and can't be removed
    /// from the UI, so uninstall must unregister it (mirrors the daemon path).
    var hasRegistration: Bool { get }
    func register() throws
    func unregister() throws
}

/// Production control backed by the real `SMAppService.mainApp`.
@MainActor
final class MainAppLaunchAgentControl: LaunchAgentControlling {
    init() {}
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var hasRegistration: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
