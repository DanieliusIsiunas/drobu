import Foundation
import IOKit
import DrobuShared

/// Why Closed Lid activation did not proceed. The privilege boundary moved to
/// the daemon (BTM approval + Team-ID XPC requirement); these are the
/// client-side outcomes that route to UI (see `route`).
enum ClosedLidError: Error, Equatable {
    case daemonNotApproved              // not registered/approved → guidance
    case protocolMismatch               // stale daemon after an update → guidance
    case authCancelled                  // user dismissed the sheet → silent
    case authFailed(String)             // lockout / unavailable → visible
    case daemonUnavailable              // XPC unreachable → visible
    case enableRejected(DaemonEnableResult) // daemon validation refused → visible
}

/// How a `ClosedLidError` surfaces to the user.
enum ClosedLidErrorRoute: Equatable {
    case silent
    case guidance                 // post `.daemonNotApproved` → "Open System Settings"
    case visibleFailure(String)   // post `.closedLidActivationFailed`
}

extension ClosedLidError {
    var route: ClosedLidErrorRoute {
        switch self {
        case .authCancelled:
            return .silent
        case .daemonNotApproved:
            return .guidance
        case .protocolMismatch:
            // Only reachable after a reinstall + re-handshake already failed —
            // approval guidance would be the wrong message (the helper IS
            // approved; its process just hasn't been replaced yet).
            return .visibleFailure("Closed Lid helper is still updating — try again in a moment.")
        case .authFailed(let reason):
            return .visibleFailure(reason)
        case .daemonUnavailable:
            return .visibleFailure("Closed Lid helper is unavailable.")
        case .enableRejected:
            return .visibleFailure("Closed Lid couldn't be activated right now.")
        }
    }
}

@MainActor
final class ClosedLidService {
    enum State: Equatable {
        case idle
        /// Active until `deadline` — the deadline is seeded from the daemon's
        /// reported remaining time (the single source of truth), never from the
        /// nominal duration, so the client and daemon clocks cannot diverge.
        case active(deadline: Date)
    }

    private(set) var state: State = .idle {
        didSet {
            Log.info("ClosedLidService: state → \(state)")
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?

    // Injected collaborators (defaults wire the real implementations).
    private let daemon: DaemonControlling
    private let auth: AuthGating
    private let registrar: DaemonRegistration
    private let now: () -> Date
    /// Test seam: when false, the unprivileged client companions (caffeinate
    /// process, clamshell IOKit monitoring, reconciliation Timer) are NOT
    /// started, so unit tests exercise the gate/state logic without spawning
    /// real processes or run-loop sources. Production always uses the default.
    private let companionsEnabled: Bool

    private var caffeinateProcess: Process?
    private var reconciliationTimer: Timer?
    private var isActivating = false
    private var clamshellPollTimer: Timer?
    private var clamshellService: io_service_t = IO_OBJECT_NULL
    private var edgeDetector = ClamshellEdgeDetector()

    /// Static, PII-free reason string (surfaces in system auth logs), < 60 chars.
    private static let authReason = "Keep your Mac awake with the lid closed"

    init(daemon: DaemonControlling = DaemonClient(),
         auth: AuthGating = AuthGate(),
         registrar: DaemonRegistration = DaemonRegistrar(),
         now: @escaping () -> Date = Date.init,
         companionsEnabled: Bool = true) {
        self.daemon = daemon
        self.auth = auth
        self.registrar = registrar
        self.now = now
        self.companionsEnabled = companionsEnabled
    }

    // MARK: - Public API

    var isActive: Bool {
        state != .idle
    }

    var remainingTime: TimeInterval? {
        guard case .active(let deadline) = state else { return nil }
        return max(0, deadline.timeIntervalSince(now()))
    }

    /// Activate Closed Lid: daemon status check → version handshake → Touch ID
    /// gate → idempotent XPC enable. `onStateChange(.active)` fires exactly once
    /// and only after every gate passes, so the badge never flashes active on a
    /// failed activation. Throws `ClosedLidError` on any non-success path.
    func start(duration: TimeInterval) async throws {
        guard !isActivating else {
            Log.debug("ClosedLidService: start() skipped — already activating")
            return
        }
        isActivating = true
        defer { isActivating = false }

        // 1. Daemon must be registered + approved. State-correct (R3): a
        //    not-registered daemon is registered inline (creating the approval
        //    toggle); anything short of .enabled routes to guidance.
        switch registrar.status {
        case .enabled:
            break
        case .notRegistered, .notFound, .failed:
            // Attempt to install the daemon. register() is idempotent and is the
            // only forward path; a never-registered daemon reports .notFound
            // (not .notRegistered) on macOS 14+, so we must try to register
            // rather than dead-end into guidance toward a toggle that doesn't
            // exist yet. The real SMAppService error (if any) is logged inside
            // register() — see DaemonRegistrar.
            let afterRegister = registrar.register()
            if afterRegister != .enabled {
                Log.info("ClosedLidService: daemon not usable after register (status: \(afterRegister)) — guiding to approval")
                throw ClosedLidError.daemonNotApproved
            }
        case .requiresApproval:
            // Already registered; the user just needs to flip the Login Items
            // toggle. Re-registering would not help — deep-link straight there.
            Log.info("ClosedLidService: daemon requires approval — guiding to System Settings")
            throw ClosedLidError.daemonNotApproved
        }

        // 2. Protocol-version handshake — never speak a newer protocol at an
        //    older daemon. A mismatch means a STALE daemon process is still
        //    running across an app update (launchd does not restart a running
        //    daemon when the bundle on disk is replaced; register() alone never
        //    bounces it). Self-heal: reinstall (unregister kills the old
        //    process, register points launchd at the new binary), then
        //    re-handshake once — the NSXPCConnection respawns the daemon on the
        //    next message after the old process dies.
        guard let daemonVersion = await daemon.protocolVersion() else {
            throw ClosedLidError.daemonUnavailable
        }
        if daemonVersion != drobuDaemonProtocolVersion {
            Log.info("ClosedLidService: daemon protocol \(daemonVersion) != \(drobuDaemonProtocolVersion) — reinstalling stale daemon")
            guard registrar.reinstall() == .enabled else {
                // BTM dropped the approval across the reinstall — the approval
                // guidance is now genuinely the right message.
                throw ClosedLidError.daemonNotApproved
            }
            if companionsEnabled {
                // Give BTM a beat to finish tearing down the old process so the
                // re-handshake spawns the new binary, not the dying one. Skipped
                // under the test seam (mocks have no process to bounce).
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let retried = await daemon.protocolVersion() else {
                throw ClosedLidError.daemonUnavailable
            }
            guard retried == drobuDaemonProtocolVersion else {
                throw ClosedLidError.protocolMismatch
            }
        }

        // 3. Consent gate (Touch ID / Apple Watch / password). Cancel aborts
        //    silently; lockout/unavailable surfaces a visible failure.
        switch await auth.authenticate(reason: Self.authReason) {
        case .cancelled: throw ClosedLidError.authCancelled
        case .failed(let reason): throw ClosedLidError.authFailed(reason)
        case .success: break
        }

        // 4. Idempotent enable (daemon re-arms in place if already active).
        guard let outcome = await daemon.enable(durationSeconds: Int(duration)) else {
            throw ClosedLidError.daemonUnavailable
        }
        guard outcome.result == .ok else {
            throw ClosedLidError.enableRejected(outcome.result)
        }

        // 5. Success — seed everything from the daemon's reported remaining.
        let remaining = outcome.remaining > 0 ? outcome.remaining : duration
        state = .active(deadline: now().addingTimeInterval(remaining))
        startCaffeinate(seconds: remaining)
        startClamshellMonitoring()
        startReconciliationTimer()
    }

    /// Deactivate — confirmed-by-readback. Does not transition to `.idle` until
    /// the daemon's `disable` reply confirms reversal; on XPC failure it stays
    /// pending-reversal with reconciliation running (the watchdog deadline is
    /// the ultimate guarantee).
    func stop() async {
        guard isActive else { return }
        let confirmed = await daemon.disable()
        if confirmed == true {
            teardownClientState()
            state = .idle
        } else {
            Log.error("ClosedLidService: stop() reversal not confirmed — pending; reconciliation will resolve")
            // Keep state .active + reconciliation running; do NOT idle.
            if reconciliationTimer == nil { startReconciliationTimer() }
        }
    }

    /// Launch-time rehydration (R14): adopt a live daemon session without a new
    /// auth prompt or a second `enable`. A true orphan is the daemon's own
    /// concern (it reverses on its boot reconciliation), so there is nothing to
    /// adopt when `status` is inactive.
    func rehydrate() async {
        guard !isActive else { return }
        guard let status = await daemon.status(), status.active, status.remaining > 0 else { return }
        state = .active(deadline: now().addingTimeInterval(status.remaining))
        startCaffeinate(seconds: status.remaining)
        // Version-gate the display-off companion only: rehydrate can adopt a
        // session held by a stale pre-update daemon (launchd keeps the old
        // process running across a Sparkle update) whose v1 interface lacks
        // displayOff — never send a newer selector at it (the reply may never
        // fire, leaking the continuation). The session itself is still adopted:
        // disable()/status() exist in every protocol version, and refusing
        // adoption would make the UI lie about a live stay-awake session.
        if await daemon.protocolVersion() == drobuDaemonProtocolVersion {
            startClamshellMonitoring()
        } else {
            Log.info("ClosedLidService: rehydrated against a stale daemon — display-off disabled for this session")
        }
        startReconciliationTimer()
        Log.info("ClosedLidService: rehydrated live session, \(Int(status.remaining))s remaining")
    }

    /// Terminate path (SIGTERM/SIGHUP/applicationWillTerminate). Bounded-wait
    /// disable (reply on a non-main queue, so blocking here cannot deadlock —
    /// M7); a missed message defers reversal to the daemon watchdog deadline
    /// (stated behavior change vs the old synchronous sudo reversal).
    func cleanup() {
        guard isActive else { return }
        _ = daemon.disableBounded(timeout: 0.4)
        // Release the IOKit poll source before exit. No brightness restore is
        // needed: display-off is `pmset displaysleepnow` daemon-side, and the
        // lid/HID wake relights the panel without app involvement.
        stopClamshellMonitoring()
        if let proc = caffeinateProcess, proc.isRunning { proc.terminate() }
        caffeinateProcess = nil
    }

    // MARK: - Private

    /// Client-side teardown only — never touches the daemon (used when the
    /// session has already ended daemon-side, via stop-confirmed or expiry).
    private func teardownClientState() {
        stopClamshellMonitoring()
        if let proc = caffeinateProcess {
            caffeinateProcess = nil
            if proc.isRunning { proc.terminate() }
        }
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
    }

    private func startCaffeinate(seconds: TimeInterval) {
        guard companionsEnabled else { return }
        if let old = caffeinateProcess, old.isRunning {
            old.terminate()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // No -d flag: allow display to sleep when lid is closed. -t seeded from
        // the daemon's remaining time so the companion cannot outlive the
        // daemon's deadline.
        proc.arguments = ["-ims", "-t", "\(Int(seconds))"]

        // Companion only — its termination must not drive daemon/session state
        // (the daemon owns the deadline; reconciliation drives teardown).
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self, self.caffeinateProcess === terminatedProcess else { return }
                self.caffeinateProcess = nil
            }
        }

        do {
            try proc.run()
            Log.debug("ClosedLidService: launched caffeinate pid=\(proc.processIdentifier), seconds=\(Int(seconds))")
            caffeinateProcess = proc
        } catch {
            // Belt-and-suspenders: a failed caffeinate spawn does NOT fail the
            // session — disablesleep is already on daemon-side.
            Log.error("ClosedLidService: failed to launch caffeinate: \(error)")
        }
    }

    private func startReconciliationTimer() {
        guard companionsEnabled else { return }
        reconciliationTimer?.invalidate()
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reconcileTick() }
        }
    }

    /// Polls the daemon (the single source of truth) and tears down client
    /// state once the session has ended. Also a belt-and-suspenders local
    /// expiry check.
    func reconcileTick() async {
        guard isActive else { return }
        if let remaining = remainingTime, remaining <= 0 {
            teardownClientState()
            state = .idle
            return
        }
        if let status = await daemon.status(), !status.active {
            Log.info("ClosedLidService: daemon reports session ended — tearing down")
            teardownClientState()
            state = .idle
        }
        // status == nil (XPC unreachable): leave state as-is; retry next tick.
    }

    // MARK: - Clamshell Monitoring (lid-close → display-off)

    /// Lid detection is a 500ms POLL of the `AppleClamshellState` property on
    /// `IOPMrootDomain` — the interest-notification path
    /// (`kIOPMMessageClamshellStateChange`) never fans out on Apple Silicon,
    /// while the kernel sets the property *before* messaging clients, making
    /// the poll authoritative even where the notification is dead.
    private func startClamshellMonitoring() {
        guard companionsEnabled else { return }
        stopClamshellMonitoring()

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            Log.error("ClosedLidService: IOPMrootDomain not found — lid detection unavailable")
            return
        }
        clamshellService = service
        edgeDetector = ClamshellEdgeDetector()

        // Manual .common-mode registration: a scheduledTimer registers in
        // .default only and would freeze while a menu is open
        // (.claude/rules/nsmenu-statusitem-gotchas.md).
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clamshellPollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clamshellPollTimer = timer
        Log.info("ClosedLidService: clamshell polling started")
    }

    private func stopClamshellMonitoring() {
        clamshellPollTimer?.invalidate()
        clamshellPollTimer = nil
        if clamshellService != IO_OBJECT_NULL {
            IOObjectRelease(clamshellService)
            clamshellService = IO_OBJECT_NULL
        }
    }

    private func clamshellPollTick() {
        guard isActive, clamshellService != IO_OBJECT_NULL else { return }
        let raw = IORegistryEntryCreateCFProperty(
            clamshellService, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        guard let edge = edgeDetector.ingest(parseClamshellState(raw)) else { return }
        Task { @MainActor [weak self] in await self?.handleClamshellChange(isClosed: edge == .closed) }
    }

    /// Edge dispatch — called once per lid transition (the detector swallows
    /// repeated same-state readings). Best-effort by design: display-off is
    /// cosmetic relative to the stay-awake guarantee, so an XPC failure logs
    /// and leaves the session untouched. The open edge needs no daemon call —
    /// the lid/HID wake relights the panel on its own.
    func handleClamshellChange(isClosed: Bool) async {
        guard isActive else { return }
        guard isClosed else {
            Log.info("ClosedLidService: lid opened — panel restored by lid wake")
            return
        }
        if await daemon.displayOff() == true {
            Log.info("ClosedLidService: lid closed — display off")
        } else {
            Log.error("ClosedLidService: lid closed but displayOff failed — session unaffected, panel may stay lit")
        }
    }
}
