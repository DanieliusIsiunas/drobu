import Foundation
import Testing
@testable import DrobuCore
import DrobuShared

// MARK: - Mocks

final class MockDaemonControl: DaemonControlling, @unchecked Sendable {
    var versionToReturn: Int? = drobuDaemonProtocolVersion
    var enableOutcome: EnableOutcome? = EnableOutcome(result: .ok, remaining: 3600)
    var disableResult: Bool? = true
    var statusReply: DaemonStatusReply?

    private(set) var enabledDurations: [Int] = []
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var statusCallCount = 0

    func protocolVersion() async -> Int? { versionToReturn }
    func enable(durationSeconds: Int) async -> EnableOutcome? {
        enableCallCount += 1
        enabledDurations.append(durationSeconds)
        return enableOutcome
    }
    func disable() async -> Bool? { disableCallCount += 1; return disableResult }
    func status() async -> DaemonStatusReply? { statusCallCount += 1; return statusReply }
    func disableBounded(timeout: TimeInterval) -> Bool { disableCallCount += 1; return disableResult ?? false }
}

final class MockAuthGate: AuthGating, @unchecked Sendable {
    var result: AuthResult = .success
    private(set) var callCount = 0
    func authenticate(reason: String) async -> AuthResult { callCount += 1; return result }
}

/// Auth gate that runs a hook during evaluation — used to drive a re-entrant
/// `start()` while the first is suspended, deterministically on the MainActor.
final class ReentrantAuthGate: AuthGating, @unchecked Sendable {
    var result: AuthResult = .success
    var onAuthenticate: (@Sendable () async -> Void)?
    private(set) var callCount = 0
    func authenticate(reason: String) async -> AuthResult {
        callCount += 1
        if let onAuthenticate { await onAuthenticate() }
        return result
    }
}

@MainActor
final class MockRegistration: DaemonRegistration {
    private var statusValue: DaemonStatus
    private let registerResult: DaemonStatus
    private(set) var registerCallCount = 0

    init(status: DaemonStatus, registerResult: DaemonStatus? = nil) {
        self.statusValue = status
        self.registerResult = registerResult ?? status
    }
    var status: DaemonStatus { statusValue }
    func register() -> DaemonStatus {
        registerCallCount += 1
        statusValue = registerResult
        return registerResult
    }
}

// MARK: - Tests

@MainActor
@Suite("ClosedLidService")
struct ClosedLidServiceTests {
    private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeService(daemon: MockDaemonControl = MockDaemonControl(),
                             auth: any AuthGating = MockAuthGate(),
                             registration: MockRegistration = MockRegistration(status: .enabled))
    -> ClosedLidService {
        ClosedLidService(daemon: daemon, auth: auth, registrar: registration,
                         now: { Date(timeIntervalSinceReferenceDate: 1_000_000) },
                         companionsEnabled: false)
    }

    @Test("happy path: enabled + version match + auth success → active exactly once, correct duration")
    func happyPath() async throws {
        let daemon = MockDaemonControl()
        daemon.enableOutcome = EnableOutcome(result: .ok, remaining: 3600)
        let service = makeService(daemon: daemon)
        var nonIdleFires = 0
        service.onStateChange = { if $0 != .idle { nonIdleFires += 1 } }

        try await service.start(duration: 3600)

        #expect(service.isActive)
        #expect(nonIdleFires == 1)                       // .active fired exactly once
        #expect(daemon.enabledDurations == [3600])       // daemon got the right duration
        #expect((service.remainingTime ?? 0) == 3600)    // seeded from daemon remaining
    }

    @Test("auth success is the password-fallback success path → proceeds to enable")
    func authSuccessProceeds() async throws {
        let daemon = MockDaemonControl()
        let auth = MockAuthGate(); auth.result = .success   // password sheet success resolves here
        let service = makeService(daemon: daemon, auth: auth)
        try await service.start(duration: 1800)
        #expect(service.isActive)
        #expect(daemon.enabledDurations == [1800])
    }

    @Test("auth cancel stays idle and never calls the daemon")
    func authCancel() async {
        let daemon = MockDaemonControl()
        let auth = MockAuthGate(); auth.result = .cancelled
        let service = makeService(daemon: daemon, auth: auth)
        await #expect(throws: ClosedLidError.authCancelled) {
            try await service.start(duration: 3600)
        }
        #expect(!service.isActive)
        #expect(daemon.enableCallCount == 0)
    }

    @Test("auth failure (lockout/unavailable) surfaces a visible failure and stays idle")
    func authFailed() async {
        let daemon = MockDaemonControl()
        let auth = MockAuthGate(); auth.result = .failed("locked")
        let service = makeService(daemon: daemon, auth: auth)
        await #expect(throws: ClosedLidError.authFailed("locked")) {
            try await service.start(duration: 3600)
        }
        #expect(!service.isActive)
        #expect(daemon.enableCallCount == 0)
    }

    @Test("requiresApproval → guidance, no auth prompt, no enable")
    func requiresApproval() async {
        let daemon = MockDaemonControl()
        let auth = MockAuthGate()
        let service = makeService(daemon: daemon, auth: auth, registration: MockRegistration(status: .requiresApproval))
        await #expect(throws: ClosedLidError.daemonNotApproved) {
            try await service.start(duration: 3600)
        }
        #expect(auth.callCount == 0)
        #expect(daemon.enableCallCount == 0)
        #expect(!service.isActive)
    }

    @Test("notRegistered registers inline then routes to guidance when approval is required")
    func notRegisteredGuides() async {
        let reg = MockRegistration(status: .notRegistered, registerResult: .requiresApproval)
        let daemon = MockDaemonControl()
        let auth = MockAuthGate()
        let service = makeService(daemon: daemon, auth: auth, registration: reg)
        await #expect(throws: ClosedLidError.daemonNotApproved) {
            try await service.start(duration: 3600)
        }
        #expect(reg.registerCallCount == 1)
        #expect(auth.callCount == 0)
        #expect(daemon.enableCallCount == 0)
    }

    @Test("notRegistered that becomes enabled after register proceeds")
    func notRegisteredBecomesEnabled() async throws {
        let reg = MockRegistration(status: .notRegistered, registerResult: .enabled)
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon, registration: reg)
        try await service.start(duration: 1800)
        #expect(reg.registerCallCount == 1)
        #expect(service.isActive)
        #expect(daemon.enabledDurations == [1800])
    }

    @Test("protocol mismatch refuses, re-registers, and never prompts or enables")
    func protocolMismatch() async {
        let daemon = MockDaemonControl(); daemon.versionToReturn = drobuDaemonProtocolVersion + 1
        let auth = MockAuthGate()
        let reg = MockRegistration(status: .enabled)
        let service = makeService(daemon: daemon, auth: auth, registration: reg)
        await #expect(throws: ClosedLidError.protocolMismatch) {
            try await service.start(duration: 3600)
        }
        #expect(reg.registerCallCount == 1)
        #expect(auth.callCount == 0)
        #expect(daemon.enableCallCount == 0)
    }

    @Test("unreachable daemon at handshake → daemonUnavailable before auth")
    func handshakeUnreachable() async {
        let daemon = MockDaemonControl(); daemon.versionToReturn = nil
        let auth = MockAuthGate()
        let service = makeService(daemon: daemon, auth: auth)
        await #expect(throws: ClosedLidError.daemonUnavailable) {
            try await service.start(duration: 3600)
        }
        #expect(auth.callCount == 0)
    }

    @Test("XPC failure after auth → daemonUnavailable, idle, auth was consumed")
    func xpcFailureAfterAuth() async {
        let daemon = MockDaemonControl(); daemon.enableOutcome = nil
        let auth = MockAuthGate()
        let service = makeService(daemon: daemon, auth: auth)
        await #expect(throws: ClosedLidError.daemonUnavailable) {
            try await service.start(duration: 3600)
        }
        #expect(auth.callCount == 1)
        #expect(!service.isActive)
    }

    @Test("daemon validation rejection surfaces as enableRejected")
    func enableRejected() async {
        let daemon = MockDaemonControl()
        daemon.enableOutcome = EnableOutcome(result: .dutyCycleExceeded, remaining: 0)
        let service = makeService(daemon: daemon)
        await #expect(throws: ClosedLidError.enableRejected(.dutyCycleExceeded)) {
            try await service.start(duration: 3600)
        }
        #expect(!service.isActive)
    }

    @Test("stop confirmed-by-readback goes idle")
    func stopConfirmed() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        daemon.disableResult = true
        await service.stop()
        #expect(!service.isActive)
        #expect(daemon.disableCallCount >= 1)
    }

    @Test("stop with XPC failure stays pending-reversal (not idle)")
    func stopUnconfirmedPending() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        daemon.disableResult = nil    // XPC failure on disable
        await service.stop()
        #expect(service.isActive)     // NOT idle — reversal pending
    }

    @Test("launch rehydration adopts a live session without a second enable")
    func rehydrateLive() async {
        let daemon = MockDaemonControl()
        daemon.statusReply = DaemonStatusReply(active: true, remaining: 1200)
        let service = makeService(daemon: daemon)
        await service.rehydrate()
        #expect(service.isActive)
        #expect((service.remainingTime ?? 0) == 1200)
        #expect(daemon.enableCallCount == 0)
    }

    @Test("launch rehydration with no live session stays idle")
    func rehydrateNoSession() async {
        let daemon = MockDaemonControl()
        daemon.statusReply = DaemonStatusReply(active: false, remaining: 0)
        let service = makeService(daemon: daemon)
        await service.rehydrate()
        #expect(!service.isActive)
    }

    @Test("reconciliation tears down once the daemon reports the session ended")
    func reconcileExpiry() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        #expect(service.isActive)
        daemon.statusReply = DaemonStatusReply(active: false, remaining: 0)
        await service.reconcileTick()
        #expect(!service.isActive)
    }

    @Test("reconciliation leaves the session active when the daemon is unreachable")
    func reconcileStaysActiveOnUnreachable() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        daemon.statusReply = nil   // status() returns nil (XPC unreachable)
        await service.reconcileTick()
        #expect(service.isActive)  // leave state as-is; retry next tick
    }

    @Test("start falls back to the nominal duration when the daemon reports remaining 0")
    func startFallsBackToNominal() async throws {
        let daemon = MockDaemonControl()
        daemon.enableOutcome = EnableOutcome(result: .ok, remaining: 0)
        let service = makeService(daemon: daemon)
        try await service.start(duration: 1800)
        #expect(service.isActive)
        #expect((service.remainingTime ?? 0) == 1800)   // not 0 — fell back to nominal
    }

    @Test("rehydration stays idle when the daemon is unreachable")
    func rehydrateUnreachableStaysIdle() async {
        let daemon = MockDaemonControl()
        daemon.statusReply = nil   // status() returns nil
        let service = makeService(daemon: daemon)
        await service.rehydrate()
        #expect(!service.isActive)
    }

    @Test("a re-entrant start while one is in flight is guarded (single enable)")
    func doubleStartGuarded() async throws {
        let daemon = MockDaemonControl()
        let gate = ReentrantAuthGate()
        let service = makeService(daemon: daemon, auth: gate)
        gate.onAuthenticate = { [weak service] in
            // Runs while the outer start is suspended at auth; isActivating is
            // still true, so this re-entrant call must be a guarded no-op.
            try? await service?.start(duration: 1800)
        }
        try await service.start(duration: 3600)
        #expect(gate.callCount == 1)                 // re-entrant call never reached auth
        #expect(daemon.enabledDurations == [3600])   // only the outer start enabled
    }

    @Test("clamshell change while idle is a no-op")
    func clamshellWhileIdle() {
        let service = makeService()
        service.handleClamshellChange(isClosed: true)
        #expect(!service.isActive)
    }

    @Test("Keep Awake is not stacked when Closed Lid stop is unconfirmed (Codex P2)")
    func keepAwakeNotStackedOnUnconfirmedStop() async throws {
        let daemon = MockDaemonControl()
        let closedLid = makeService(daemon: daemon)
        try await closedLid.start(duration: 3600)   // → .active
        daemon.disableResult = nil                   // stop() can't confirm reversal
        let caffeinate = CaffeinateService()
        let command = SleepCommand(caffeinateService: caffeinate, closedLidService: closedLid)
        await command.execute(option: CommandOption(
            id: "ka-15m", label: "15 minutes", icon: "clock", isDestructive: false, section: "Keep Awake"))
        #expect(caffeinate.isActive == false)   // NOT started on top of a lingering Closed Lid
        #expect(closedLid.isActive)             // Closed Lid stays pending-reversal
    }
}
