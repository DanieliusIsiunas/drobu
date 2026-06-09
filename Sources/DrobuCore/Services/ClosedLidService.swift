import Foundation
import IOKit
import IOKit.pwr_mgt
import DrobuShared

// Clamshell state change from xnu/iokit/IOKit/pwr_mgt/IOPM.h
private let kIOPMMessageClamshellStateChange: UInt32 = 0xE003_4100
private let kClamshellStateBit: UInt32 = 1 << 0

private let clamshellCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
    guard messageType == kIOPMMessageClamshellStateChange else { return }
    let bits = UInt32(UInt(bitPattern: messageArgument))
    let isClosed = (bits & kClamshellStateBit) != 0
    guard let refcon else { return }
    let obj = Unmanaged<ClosedLidService>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        obj.handleClamshellChange(isClosed: isClosed)
    }
}

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
    case logOnly(String)
}

extension ClosedLidError {
    var route: ClosedLidErrorRoute {
        switch self {
        case .authCancelled:
            return .silent
        case .daemonNotApproved, .protocolMismatch:
            return .guidance
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
    private var clamshellNotifyPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = IO_OBJECT_NULL
    private var savedBrightness: Float?

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
        case .notRegistered:
            if registrar.register() != .enabled { throw ClosedLidError.daemonNotApproved }
        case .requiresApproval, .notFound, .failed:
            throw ClosedLidError.daemonNotApproved
        }

        // 2. Protocol-version handshake — never speak a newer protocol at an
        //    older daemon. Mismatch → attempt to install the bundled daemon and
        //    route to re-approval guidance.
        guard let daemonVersion = await daemon.protocolVersion() else {
            throw ClosedLidError.daemonUnavailable
        }
        guard daemonVersion == drobuDaemonProtocolVersion else {
            _ = registrar.register()
            throw ClosedLidError.protocolMismatch
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
        startClamshellMonitoring()
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
        if let proc = caffeinateProcess, proc.isRunning { proc.terminate() }
        caffeinateProcess = nil
    }

    // MARK: - Private

    /// Client-side teardown only — never touches the daemon (used when the
    /// session has already ended daemon-side, via stop-confirmed or expiry).
    private func teardownClientState() {
        restoreDisplay()
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

    // MARK: - Clamshell Monitoring & Display Brightness

    private func startClamshellMonitoring() {
        guard companionsEnabled else { return }
        stopClamshellMonitoring()

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            Log.error("ClosedLidService: IOPMrootDomain not found")
            return
        }
        defer { IOObjectRelease(service) }

        let port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else {
            Log.error("ClosedLidService: failed to create notification port")
            return
        }

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = IO_OBJECT_NULL
        let kr = IOServiceAddInterestNotification(
            port, service, kIOGeneralInterest,
            clamshellCallback, refcon, &notifier
        )
        if kr != KERN_SUCCESS {
            Log.error("ClosedLidService: IOServiceAddInterestNotification failed: \(kr)")
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            IONotificationPortDestroy(port)
            return
        }

        clamshellNotifyPort = port
        clamshellNotifier = notifier
        Log.info("ClosedLidService: clamshell monitoring started")
    }

    private func stopClamshellMonitoring() {
        guard clamshellNotifier != IO_OBJECT_NULL else { return }

        IOObjectRelease(clamshellNotifier)
        clamshellNotifier = IO_OBJECT_NULL

        if let port = clamshellNotifyPort {
            let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            IONotificationPortDestroy(port)
            clamshellNotifyPort = nil
        }
    }

    func handleClamshellChange(isClosed: Bool) {
        guard isActive else { return }
        if isClosed {
            dimDisplay()
        } else {
            restoreDisplay()
        }
    }

    private func withDisplayService(_ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator
        ) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        body(service)
    }

    /// Set display brightness to 0 — no sleep cascade, just backlight off.
    private func dimDisplay() {
        withDisplayService { display in
            var current: Float = 0
            guard IODisplayGetFloatParameter(display, 0, "brightness" as CFString, &current) == kIOReturnSuccess else {
                Log.error("ClosedLidService: could not read brightness, skipping dim")
                return
            }
            savedBrightness = current
            IODisplaySetFloatParameter(display, 0, "brightness" as CFString, 0)
            Log.info("ClosedLidService: lid closed — display dimmed (was \(current))")
        }
    }

    /// Restore display brightness to the value saved before dimming.
    private func restoreDisplay() {
        guard let brightness = savedBrightness else { return }
        savedBrightness = nil
        withDisplayService { display in
            IODisplaySetFloatParameter(display, 0, "brightness" as CFString, brightness)
            Log.info("ClosedLidService: display brightness restored to \(brightness)")
        }
    }
}
