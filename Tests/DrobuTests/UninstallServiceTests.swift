import Foundation
import Testing
@testable import DrobuCore
import DrobuShared

// MARK: - Recording mocks (capture call order across collaborators)

/// Thread-safe ordered call log. Lock-guarded so the Sendable mocks (daemon,
/// trasher) can record from a nonisolated async context without a data race.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []
    func record(_ step: String) { lock.lock(); _steps.append(step); lock.unlock() }
    var steps: [String] { lock.lock(); defer { lock.unlock() }; return _steps }
}

final class UninstallDaemonMock: DaemonControlling, @unchecked Sendable {
    let log: StepLog
    var disableResult: Bool?
    var teardownResult: Bool?
    init(log: StepLog, disableResult: Bool? = true, teardownResult: Bool? = true) {
        self.log = log
        self.disableResult = disableResult
        self.teardownResult = teardownResult
    }
    func protocolVersion() async -> Int? { nil }
    func enable(durationSeconds: Int) async -> EnableOutcome? { nil }
    func disable() async -> Bool? { disableResult }
    func displayOff() async -> Bool? { nil }
    func status() async -> DaemonStatusReply? { nil }
    func resetConnection() { log.record("resetConnection") }
    // UninstallService uses the bounded (semaphore) variants — record there.
    func disableBounded(timeout: TimeInterval) -> Bool { log.record("disable"); return disableResult ?? false }
    func teardownBounded(timeout: TimeInterval) -> Bool { log.record("teardown"); return teardownResult ?? false }
}

@MainActor
final class UninstallRegistrationMock: DaemonRegistration {
    let log: StepLog
    private var statusValue: DaemonStatus
    private let unregisterResult: DaemonStatus
    init(log: StepLog, status: DaemonStatus, unregisterResult: DaemonStatus = .notRegistered) {
        self.log = log
        self.statusValue = status
        self.unregisterResult = unregisterResult
    }
    var status: DaemonStatus { statusValue }
    func register() -> DaemonStatus { statusValue }
    func reinstall() async -> DaemonStatus { statusValue }
    func unregister() -> DaemonStatus { log.record("unregister"); statusValue = unregisterResult; return unregisterResult }
}

@MainActor
final class UninstallLaunchAgentMock: LaunchAgentControlling {
    let log: StepLog
    private var enabled: Bool
    private let throwOnUnregister: Error?
    private let enabledAfterThrow: Bool
    init(log: StepLog, enabled: Bool, throwOnUnregister: Error? = nil, enabledAfterThrow: Bool = false) {
        self.log = log
        self.enabled = enabled
        self.throwOnUnregister = throwOnUnregister
        self.enabledAfterThrow = enabledAfterThrow
    }
    var isEnabled: Bool { enabled }
    func register() throws { log.record("launchRegister") }
    func unregister() throws {
        log.record("launchUnregister")
        if let throwOnUnregister { enabled = enabledAfterThrow; throw throwOnUnregister }
        enabled = false
    }
}

final class UninstallEraserMock: DataErasing {
    let log: StepLog
    private let throwError: Error?
    init(log: StepLog, throwError: Error? = nil) { self.log = log; self.throwError = throwError }
    func eraseAllUserData() throws { log.record("erase"); if let throwError { throw throwError } }
}

final class UninstallTrasherMock: BundleTrashing, @unchecked Sendable {
    let log: StepLog
    init(log: StepLog) { self.log = log }
    func scheduleTrash(bundleURL: URL) { log.record("scheduleTrash") }
}

// MARK: - Tests

@MainActor
@Suite("UninstallService")
struct UninstallServiceTests {

    private struct Harness {
        let service: UninstallService
        let log: StepLog
    }

    private func makeHarness(
        daemonStatus: DaemonStatus = .enabled,
        disableResult: Bool? = true,
        teardownResult: Bool? = true,
        unregisterResult: DaemonStatus = .notRegistered,
        loginEnabled: Bool = true,
        loginThrow: Error? = nil,
        loginEnabledAfterThrow: Bool = false,
        eraseThrow: Error? = nil
    ) -> Harness {
        let log = StepLog()
        let service = UninstallService(
            daemon: UninstallDaemonMock(log: log, disableResult: disableResult, teardownResult: teardownResult),
            registrar: UninstallRegistrationMock(log: log, status: daemonStatus, unregisterResult: unregisterResult),
            launchAgent: UninstallLaunchAgentMock(log: log, enabled: loginEnabled,
                                                  throwOnUnregister: loginThrow, enabledAfterThrow: loginEnabledAfterThrow),
            dataEraser: UninstallEraserMock(log: log, throwError: eraseThrow),
            trasher: UninstallTrasherMock(log: log),
            bundleURL: URL(fileURLWithPath: "/tmp/Drobu.app"),
            terminate: { log.record("terminate") })
        return Harness(service: service, log: log)
    }

    @Test("happy path runs steps in order: disable → teardown → unregister → resetConnection → launchUnregister")
    func happyOrder() async {
        let h = makeHarness()
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(h.log.steps == ["disable", "teardown", "unregister", "resetConnection", "launchUnregister"])
        #expect(result.sessionReversal == .ok)
        #expect(result.daemonStateTeardown == .ok)
        #expect(result.daemonUnregister == .ok)
        #expect(result.launchAtLoginUnregister == .ok)
        #expect(result.dataErase == .skipped)
        #expect(!result.hadRegistrationFailure)
    }

    @Test("session reversal precedes daemon unregister (R14)")
    func reversalBeforeUnregister() async {
        let h = makeHarness()
        _ = await h.service.run(options: UninstallOptions(deleteData: false))
        let steps = h.log.steps
        #expect(steps.firstIndex(of: "disable")! < steps.firstIndex(of: "unregister")!)
    }

    @Test("deleteData true invokes the eraser after the registration steps")
    func deleteDataErases() async {
        let h = makeHarness()
        let result = await h.service.run(options: UninstallOptions(deleteData: true))
        #expect(h.log.steps == ["disable", "teardown", "unregister", "resetConnection", "launchUnregister", "erase"])
        #expect(result.dataErase == .ok)
    }

    @Test("deleteData false never invokes the eraser")
    func deleteDataFalseSkipsErase() async {
        let h = makeHarness()
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(!h.log.steps.contains("erase"))
        #expect(result.dataErase == .skipped)
    }

    @Test("an old daemon without teardown (nil) is skipped, not failed — unregister still runs")
    func teardownUnsupportedContinues() async {
        let h = makeHarness(teardownResult: nil)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(result.daemonStateTeardown == .skipped)
        #expect(result.daemonUnregister == .ok)
        #expect(h.log.steps.contains("unregister"))
    }

    @Test("no registered daemon: daemon steps skipped, connection reset + login still handled")
    func noDaemonSkipsDaemonSteps() async {
        let h = makeHarness(daemonStatus: .notRegistered)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(result.sessionReversal == .skipped)
        #expect(result.daemonStateTeardown == .skipped)
        #expect(result.daemonUnregister == .skipped)
        #expect(!h.log.steps.contains("disable"))
        #expect(!h.log.steps.contains("unregister"))
        #expect(h.log.steps.contains("resetConnection"))
        #expect(h.log.steps.contains("launchUnregister"))
    }

    @Test("launch-at-login not enabled → skipped, no unregister call")
    func loginNotEnabledSkips() async {
        let h = makeHarness(loginEnabled: false)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(result.launchAtLoginUnregister == .skipped)
        #expect(!h.log.steps.contains("launchUnregister"))
    }

    @Test("daemon unregister failure → .failed, hadRegistrationFailure, residual summary; later steps still run")
    func unregisterFailureSurfacesResidual() async {
        let h = makeHarness(unregisterResult: .failed("Operation not permitted"))
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        if case .failed = result.daemonUnregister {} else { Issue.record("expected .failed daemonUnregister") }
        #expect(result.hadRegistrationFailure)
        #expect(result.residualSummary != nil)
        #expect(h.log.steps.contains("resetConnection"))   // continued past the failure
        #expect(h.log.steps.contains("launchUnregister"))
    }

    @Test("session reversal failure is not a registration failure and does not block unregister")
    func reversalFailureIsTolerated() async {
        let h = makeHarness(disableResult: nil)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(result.sessionReversal == .failed("session reversal unconfirmed"))
        #expect(result.daemonUnregister == .ok)
        #expect(!result.hadRegistrationFailure)   // a stranded session ≠ orphaned Login Item
    }

    @Test("run() never trashes; scheduleSelfDeleteAndQuit trashes then terminates (trash last)")
    func trashOnlyOnSelfDelete() async {
        let h = makeHarness()
        _ = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(!h.log.steps.contains("scheduleTrash"))
        h.service.scheduleSelfDeleteAndQuit()
        #expect(Array(h.log.steps.suffix(2)) == ["scheduleTrash", "terminate"])
    }

    @Test("a registered-but-unapproved daemon (.requiresApproval) still gets unregistered, no disable/teardown")
    func requiresApprovalStillUnregisters() async {
        let h = makeHarness(daemonStatus: .requiresApproval)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(!h.log.steps.contains("disable"))     // not running — no session to reverse
        #expect(!h.log.steps.contains("teardown"))    // not running — nothing to erase via XPC
        #expect(h.log.steps.contains("unregister"))   // but the orphan-able record IS removed
        #expect(result.sessionReversal == .skipped)
        #expect(result.daemonStateTeardown == .skipped)
        #expect(result.daemonUnregister == .ok)
    }

    @Test("disable() returning false (not nil) is a failed reversal, not skipped — unregister still proceeds")
    func disableFalseIsFailure() async {
        let h = makeHarness(disableResult: false)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(result.sessionReversal == .failed("session reversal unconfirmed"))
        #expect(result.daemonUnregister == .ok)
    }

    @Test("launch-at-login unregister throws while still enabled → failed + residual summary")
    func loginUnregisterThrowsStillEnabled() async {
        let h = makeHarness(loginThrow: StubError(), loginEnabledAfterThrow: true)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        if case .failed = result.launchAtLoginUnregister {} else { Issue.record("expected .failed launchAtLoginUnregister") }
        #expect(result.hadRegistrationFailure)
        #expect(result.residualSummary != nil)
    }

    @Test("launch-at-login throws but is gone afterward → treated as success")
    func loginUnregisterThrowsButRemoved() async {
        let h = makeHarness(loginThrow: StubError(), loginEnabledAfterThrow: false)
        let result = await h.service.run(options: UninstallOptions(deleteData: false))
        #expect(result.launchAtLoginUnregister == .ok)
        #expect(!result.hadRegistrationFailure)
    }

    @Test("data-erase failure surfaces as .failed and is not a registration failure")
    func eraseFailureIsFailed() async {
        let h = makeHarness(eraseThrow: StubError())
        let result = await h.service.run(options: UninstallOptions(deleteData: true))
        if case .failed = result.dataErase {} else { Issue.record("expected .failed dataErase") }
        #expect(!result.hadRegistrationFailure)   // a data-wipe failure leaves no orphaned registration
        #expect(result.residualSummary != nil)    // ...but the user IS warned their data may remain
    }

    @Test("checkbox state maps to UninstallOptions.deleteData")
    func optionsMapping() {
        #expect(UninstallOptions(deleteData: true).deleteData == true)
        #expect(UninstallOptions(deleteData: false).deleteData == false)
    }
}
