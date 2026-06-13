import Foundation
import Testing
@testable import DrobuCore
import DrobuShared

// MARK: - Mocks

final class MockDaemonControl: DaemonControlling, @unchecked Sendable {
    var versionToReturn: Int? = drobuDaemonProtocolVersion
    /// When non-empty, protocolVersion() consumes from here first — lets a test
    /// model a stale daemon that is replaced mid-start (reinstall self-heal).
    var versionSequence: [Int?] = []
    var enableOutcome: EnableOutcome? = EnableOutcome(result: .ok, remaining: 3600)
    var disableResult: Bool? = true
    var displayOffResult: Bool? = true
    var teardownResult: Bool? = true
    var statusReply: DaemonStatusReply?

    private(set) var enabledDurations: [Int] = []
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var displayOffCallCount = 0
    private(set) var teardownCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var resetConnectionCallCount = 0

    func protocolVersion() async -> Int? {
        if !versionSequence.isEmpty { return versionSequence.removeFirst() }
        return versionToReturn
    }
    func enable(durationSeconds: Int) async -> EnableOutcome? {
        enableCallCount += 1
        enabledDurations.append(durationSeconds)
        return enableOutcome
    }
    func disable() async -> Bool? { disableCallCount += 1; return disableResult }
    func teardown() async -> Bool? { teardownCallCount += 1; return teardownResult }
    func displayOff() async -> Bool? { displayOffCallCount += 1; return displayOffResult }
    func status() async -> DaemonStatusReply? { statusCallCount += 1; return statusReply }
    func disableBounded(timeout: TimeInterval) -> Bool { disableCallCount += 1; return disableResult ?? false }
    func resetConnection() { resetConnectionCallCount += 1 }
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
    private let reinstallResult: DaemonStatus
    private let unregisterResult: DaemonStatus
    private(set) var registerCallCount = 0
    private(set) var reinstallCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: DaemonStatus, registerResult: DaemonStatus? = nil,
         reinstallResult: DaemonStatus? = nil, unregisterResult: DaemonStatus = .notRegistered) {
        self.statusValue = status
        self.registerResult = registerResult ?? status
        self.reinstallResult = reinstallResult ?? registerResult ?? status
        self.unregisterResult = unregisterResult
    }
    var status: DaemonStatus { statusValue }
    func register() -> DaemonStatus {
        registerCallCount += 1
        statusValue = registerResult
        return registerResult
    }
    func reinstall() async -> DaemonStatus {
        reinstallCallCount += 1
        statusValue = reinstallResult
        return reinstallResult
    }
    func unregister() -> DaemonStatus {
        unregisterCallCount += 1
        statusValue = unregisterResult
        return unregisterResult
    }
}

// MARK: - Tests

@MainActor
@Suite("ClosedLidService")
struct ClosedLidServiceTests {
    private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeService(daemon: MockDaemonControl = MockDaemonControl(),
                             auth: any AuthGating = MockAuthGate(),
                             registration: MockRegistration = MockRegistration(status: .enabled),
                             handshakeMaxAttempts: Int = 5)
    -> ClosedLidService {
        ClosedLidService(daemon: daemon, auth: auth, registrar: registration,
                         now: { Date(timeIntervalSinceReferenceDate: 1_000_000) },
                         companionsEnabled: false,
                         handshakeMaxAttempts: handshakeMaxAttempts)
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

    @Test("protocol mismatch self-heals: reinstall bounces the stale daemon, then proceeds")
    func protocolMismatchSelfHeals() async throws {
        let daemon = MockDaemonControl()
        daemon.versionSequence = [drobuDaemonProtocolVersion + 1]   // stale once, current after reinstall
        let auth = MockAuthGate()
        let reg = MockRegistration(status: .enabled)
        let service = makeService(daemon: daemon, auth: auth, registration: reg)
        try await service.start(duration: 3600)
        #expect(reg.reinstallCallCount == 1)
        #expect(service.isActive)
        #expect(auth.callCount == 1)                 // healed BEFORE the consent gate
        #expect(daemon.enabledDurations == [3600])
    }

    @Test("persistent protocol mismatch after reinstall refuses without prompting or enabling")
    func protocolMismatchPersists() async {
        let daemon = MockDaemonControl(); daemon.versionToReturn = drobuDaemonProtocolVersion + 1
        let auth = MockAuthGate()
        let reg = MockRegistration(status: .enabled)
        let service = makeService(daemon: daemon, auth: auth, registration: reg)
        await #expect(throws: ClosedLidError.protocolMismatch) {
            try await service.start(duration: 3600)
        }
        #expect(reg.reinstallCallCount == 1)
        #expect(auth.callCount == 0)
        #expect(daemon.enableCallCount == 0)
    }

    @Test("reinstall that loses BTM approval routes to approval guidance")
    func reinstallLosesApproval() async {
        let daemon = MockDaemonControl(); daemon.versionToReturn = drobuDaemonProtocolVersion + 1
        let reg = MockRegistration(status: .enabled, reinstallResult: .requiresApproval)
        let service = makeService(daemon: daemon, registration: reg)
        await #expect(throws: ClosedLidError.daemonNotApproved) {
            try await service.start(duration: 3600)
        }
        #expect(reg.reinstallCallCount == 1)
        #expect(!service.isActive)
    }

    @Test("reinstall register-failure (BTM teardown race) is 'still updating', not approval guidance")
    func reinstallFailureRoutesToStillUpdating() async {
        let daemon = MockDaemonControl(); daemon.versionToReturn = drobuDaemonProtocolVersion + 1
        let reg = MockRegistration(status: .enabled, reinstallResult: .failed("Operation not permitted"))
        let service = makeService(daemon: daemon, registration: reg)
        await #expect(throws: ClosedLidError.protocolMismatch) {
            try await service.start(duration: 3600)
        }
        // The route carries the truthful retry message — not the approval alert.
        #expect(ClosedLidError.protocolMismatch.route
                == .visibleFailure("Closed Lid helper is still updating — try again in a moment."))
    }

    @Test("transient unreachable heals via handshake retry — NO reinstall, no auth delay")
    func transientUnreachableHealedByRetry() async throws {
        // The real post-update shape: one (or a few) nil replies during the
        // launchd bundle-swap window, then the daemon answers. The bounded
        // retry rides it out without the heavy reinstall.
        let daemon = MockDaemonControl()
        daemon.versionSequence = [nil, nil]   // unreachable twice; current on the 3rd attempt
        let auth = MockAuthGate()
        let reg = MockRegistration(status: .enabled)
        let service = makeService(daemon: daemon, auth: auth, registration: reg)
        try await service.start(duration: 3600)
        #expect(reg.reinstallCallCount == 0)            // retry handled it — no reinstall
        #expect(daemon.resetConnectionCallCount == 2)   // dropped the stale connection between tries
        #expect(service.isActive)
        #expect(auth.callCount == 1)
        #expect(daemon.enabledDurations == [3600])
    }

    @Test("persistently unreachable daemon → retry exhausts, escalates to ONE reinstall, then daemonUnavailable")
    func handshakeUnreachable() async {
        let daemon = MockDaemonControl(); daemon.versionToReturn = nil   // never answers
        let auth = MockAuthGate()
        let reg = MockRegistration(status: .enabled)
        let service = makeService(daemon: daemon, auth: auth, registration: reg)
        await #expect(throws: ClosedLidError.daemonUnavailable) {
            try await service.start(duration: 3600)
        }
        #expect(reg.reinstallCallCount == 1)   // retry exhausted → one escalation bounce
        #expect(auth.callCount == 0)
    }

    @Test("unreachable that persists through retries but answers after a reinstall bounce")
    func persistentUnreachableHealedByReinstall() async throws {
        // No-retry seam (handshakeMaxAttempts: 1): the first handshake is a
        // single nil → escalate to reinstall → fresh daemon answers.
        let daemon = MockDaemonControl()
        daemon.versionSequence = [nil]   // first (only) attempt nil; versionToReturn (current) after
        let auth = MockAuthGate()
        let reg = MockRegistration(status: .enabled)
        let service = makeService(daemon: daemon, auth: auth, registration: reg, handshakeMaxAttempts: 1)
        try await service.start(duration: 3600)
        #expect(reg.reinstallCallCount == 1)
        #expect(daemon.resetConnectionCallCount == 1)   // clean dial after the reinstall
        #expect(service.isActive)
        #expect(auth.callCount == 1)
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

    @Test("clamshell close edge while idle never calls the daemon")
    func clamshellWhileIdle() async {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        await service.handleClamshellChange(isClosed: true)
        #expect(!service.isActive)
        #expect(daemon.displayOffCallCount == 0)
    }

    @Test("lid-close edge while active calls displayOff exactly once")
    func closeEdgeFiresDisplayOff() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        await service.handleClamshellChange(isClosed: true)
        #expect(daemon.displayOffCallCount == 1)
        #expect(service.isActive)
    }

    @Test("lid-open edge calls nothing — the lid wake restores the panel")
    func openEdgeIsNoDaemonCall() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        await service.handleClamshellChange(isClosed: false)
        #expect(daemon.displayOffCallCount == 0)
        #expect(service.isActive)
    }

    @Test("displayOff XPC failure is tolerated — session stays active (R8)")
    func displayOffFailureLeavesSessionActive() async throws {
        let daemon = MockDaemonControl()
        let service = makeService(daemon: daemon)
        try await service.start(duration: 3600)
        var stateChanges = 0
        service.onStateChange = { _ in stateChanges += 1 }

        daemon.displayOffResult = nil            // XPC unreachable
        await service.handleClamshellChange(isClosed: true)
        #expect(daemon.displayOffCallCount == 1) // the call was made, then tolerated
        #expect(service.isActive)
        #expect(stateChanges == 0)               // no state churn on failure

        daemon.displayOffResult = false          // daemon refused
        await service.handleClamshellChange(isClosed: true)
        #expect(daemon.displayOffCallCount == 2) // not silently skipped
        #expect(service.isActive)
        #expect(stateChanges == 0)
    }

    @Test("rehydration against a stale (version-mismatched) daemon still adopts the session")
    func rehydrateStaleDaemonStillAdopts() async {
        let daemon = MockDaemonControl()
        daemon.statusReply = DaemonStatusReply(active: true, remaining: 1200)
        daemon.versionToReturn = drobuDaemonProtocolVersion - 1   // pre-update daemon
        let service = makeService(daemon: daemon)
        await service.rehydrate()
        // Stay-awake adoption is NOT version-gated (the UI must not lie about a
        // live session) — only the display-off companion is withheld.
        #expect(service.isActive)
        #expect((service.remainingTime ?? 0) == 1200)
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
