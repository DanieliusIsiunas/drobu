import Foundation
import ServiceManagement
import Testing
@testable import DrobuCore

@MainActor
final class MockDaemonServiceControl: DaemonServiceControlling {
    var rawStatus: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    /// Status the mock transitions to after a successful `register()` — models
    /// BTM creating the approval toggle (notRegistered → requiresApproval).
    var statusAfterRegister: SMAppService.Status?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(status: SMAppService.Status) { self.rawStatus = status }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { rawStatus = statusAfterRegister }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
    }

    func openSettings() { openSettingsCallCount += 1 }
}

struct StubError: Error {}

@MainActor
@Suite("DaemonRegistrar")
struct DaemonRegistrarTests {

    @Test("maps every SMAppService.Status case")
    func statusMapping() {
        #expect(DaemonRegistrar.map(.notRegistered) == .notRegistered)
        #expect(DaemonRegistrar.map(.enabled) == .enabled)
        #expect(DaemonRegistrar.map(.requiresApproval) == .requiresApproval)
        #expect(DaemonRegistrar.map(.notFound) == .notFound)
    }

    @Test("reports the control's current status")
    func reportsStatus() {
        let control = MockDaemonServiceControl(status: .enabled)
        #expect(DaemonRegistrar(control: control).status == .enabled)
    }

    @Test("register success returns the new status")
    func registerSuccess() {
        let control = MockDaemonServiceControl(status: .notRegistered)
        control.statusAfterRegister = .requiresApproval
        let registrar = DaemonRegistrar(control: control)
        #expect(registrar.register() == .requiresApproval)
        #expect(control.registerCallCount == 1)
    }

    @Test("register failure surfaces as .failed and does not crash")
    func registerFailure() {
        let control = MockDaemonServiceControl(status: .notRegistered)
        control.registerError = StubError()
        let registrar = DaemonRegistrar(control: control)
        if case .failed = registrar.register() {} else { Issue.record("expected .failed") }
    }

    @Test("remediate: notRegistered registers inline, then deep-links when approval is required")
    func remediateNotRegistered() {
        let control = MockDaemonServiceControl(status: .notRegistered)
        control.statusAfterRegister = .requiresApproval
        let registrar = DaemonRegistrar(control: control)
        let result = registrar.remediate()
        #expect(control.registerCallCount == 1)         // registered inline (creates the toggle)
        #expect(control.openSettingsCallCount == 1)      // then deep-linked
        #expect(result == .requiresApproval)
    }

    @Test("remediate: notRegistered that becomes enabled does NOT deep-link")
    func remediateNotRegisteredBecomesEnabled() {
        let control = MockDaemonServiceControl(status: .notRegistered)
        control.statusAfterRegister = .enabled
        let registrar = DaemonRegistrar(control: control)
        let result = registrar.remediate()
        #expect(control.registerCallCount == 1)
        #expect(control.openSettingsCallCount == 0)      // no toggle needed
        #expect(result == .enabled)
    }

    @Test("remediate: requiresApproval deep-links without re-registering")
    func remediateRequiresApproval() {
        let control = MockDaemonServiceControl(status: .requiresApproval)
        let registrar = DaemonRegistrar(control: control)
        #expect(registrar.remediate() == .requiresApproval)
        #expect(control.registerCallCount == 0)          // never send a registered user back through register
        #expect(control.openSettingsCallCount == 1)
    }

    @Test("remediate: notFound attempts register inline (forward path), then deep-links if approval needed")
    func remediateNotFound() {
        // A never-registered daemon reports .notFound on macOS 14+, so remediate
        // must register() rather than send the user to a non-existent toggle.
        let control = MockDaemonServiceControl(status: .notFound)
        control.statusAfterRegister = .requiresApproval
        let registrar = DaemonRegistrar(control: control)
        let result = registrar.remediate()
        #expect(control.registerCallCount == 1)
        #expect(control.openSettingsCallCount == 1)
        #expect(result == .requiresApproval)
    }

    @Test("remediate: notFound that won't register surfaces and does not deep-link")
    func remediateNotFoundStuck() {
        // register() leaves it .notFound (statusAfterRegister unset) → no toggle exists, no deep-link.
        let control = MockDaemonServiceControl(status: .notFound)
        let registrar = DaemonRegistrar(control: control)
        let result = registrar.remediate()
        #expect(control.registerCallCount == 1)
        #expect(control.openSettingsCallCount == 0)
        #expect(result == .notFound)
    }

    @Test("remediate: enabled does nothing")
    func remediateEnabled() {
        let control = MockDaemonServiceControl(status: .enabled)
        let registrar = DaemonRegistrar(control: control)
        #expect(registrar.remediate() == .enabled)
        #expect(control.registerCallCount == 0)
        #expect(control.openSettingsCallCount == 0)
    }

    @Test("unregister recovers an orphaned binding")
    func unregister() {
        let control = MockDaemonServiceControl(status: .enabled)
        control.statusAfterRegister = nil
        let registrar = DaemonRegistrar(control: control)
        _ = registrar.unregister()
        #expect(control.unregisterCallCount == 1)
    }

    @Test("reinstall unregisters then registers — the stale-daemon bounce")
    func reinstallBounces() {
        let control = MockDaemonServiceControl(status: .enabled)
        control.statusAfterRegister = .enabled
        let registrar = DaemonRegistrar(control: control)
        #expect(registrar.reinstall() == .enabled)
        #expect(control.unregisterCallCount == 1)
        #expect(control.registerCallCount == 1)
    }

    @Test("reinstall proceeds to register even when unregister fails (orphan tolerance)")
    func reinstallToleratesUnregisterFailure() {
        let control = MockDaemonServiceControl(status: .enabled)
        control.unregisterError = StubError()
        control.statusAfterRegister = .enabled
        let registrar = DaemonRegistrar(control: control)
        #expect(registrar.reinstall() == .enabled)   // register still attempted
        #expect(control.registerCallCount == 1)
    }
}
