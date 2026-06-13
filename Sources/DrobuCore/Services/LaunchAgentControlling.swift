import Foundation
import ServiceManagement

/// Injectable seam over `SMAppService.mainApp` (launch-at-login). `SMAppService`
/// has no mockable surface, so this protocol lets the launch-at-login toggle and
/// the uninstall flow share one testable path. Mirrors `DaemonServiceControlling`.
@MainActor
protocol LaunchAgentControlling: AnyObject {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

/// Production control backed by the real `SMAppService.mainApp`.
@MainActor
final class MainAppLaunchAgentControl: LaunchAgentControlling {
    init() {}
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
