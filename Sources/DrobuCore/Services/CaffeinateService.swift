import Foundation

@MainActor
final class CaffeinateService {
    enum State: Equatable {
        case idle
        case active(startDate: Date, duration: TimeInterval)
    }

    private(set) var state: State = .idle {
        didSet {
            Log.info("CaffeinateService: state → \(state)")
            onStateChange?(state)
        }
    }

    /// Callback for state changes — set by AppDelegate to update menu bar badge.
    var onStateChange: ((State) -> Void)?

    private var process: Process?
    /// One-shot timer that ends the session at its logical deadline, so `state`
    /// (and the menu-bar badge, which is driven off `onStateChange`) clear on time
    /// instead of waiting for the OS `caffeinate` process to terminate — which can
    /// lag the deadline (a process suspended across system sleep outlives its `-t`,
    /// and the termination callback's main-actor hop may not run until wake).
    private var expiryTimer: Timer?

    var isActive: Bool {
        guard case .active(_, _) = state else { return false }
        // Treat as inactive once remaining time has elapsed,
        // even if the caffeinate process hasn't terminated yet.
        if let remaining = remainingTime, remaining <= 0 { return false }
        return true
    }

    var remainingTime: TimeInterval? {
        guard case .active(let startDate, let duration) = state else { return nil }
        let remaining = startDate.addingTimeInterval(duration).timeIntervalSinceNow
        return max(0, remaining)
    }

    func start(duration: TimeInterval) {
        // Kill existing process + pending expiry first (without terminationHandler race)
        if let old = process, old.isRunning {
            old.terminate()
        }
        process = nil
        expiryTimer?.invalidate()
        expiryTimer = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-dims", "-t", "\(Int(duration))"]

        // Only reset state if this process is still the current one.
        // This prevents a terminated old process from clobbering a new session.
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self, self.process === terminatedProcess else { return }
                self.expiryTimer?.invalidate()
                self.expiryTimer = nil
                self.state = .idle
                self.process = nil
            }
        }

        do {
            try proc.run()
            Log.debug("CaffeinateService: launched caffeinate pid=\(proc.processIdentifier), duration=\(Int(duration))s")
            process = proc
            state = .active(startDate: Date(), duration: duration)
            scheduleExpiry(after: duration)
        } catch {
            Log.error("CaffeinateService: failed to launch caffeinate: \(error)")
            state = .idle
            process = nil
        }
    }

    /// Schedule the deadline check. The menu-bar badge is driven by `state`
    /// transitions (`onStateChange`), and `state` only flips to `.idle` when the
    /// `caffeinate` process terminates — which can lag the logical deadline. Without
    /// this, the "keep awake" dot persists after the session has expired. `.common`
    /// mode so it still fires while an NSMenu is tracking (default-mode timers don't
    /// — the ClipboardMonitor idiom); a one-shot whose fire date passed during sleep
    /// fires on wake, which is exactly when we want to reconcile.
    private func scheduleExpiry(after duration: TimeInterval) {
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0, duration), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileExpiry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Idempotent deadline reconciliation: if the session reached its deadline but
    /// `state` is still `.active` (the OS process hasn't terminated yet), end it now
    /// so `state`, `isActive`, and the badge all agree. No-op unless
    /// active-and-expired, so it is safe to call any time (timer fire or a wake
    /// re-check). Mirrors `ClosedLidService.reconcileTick`.
    func reconcileExpiry() {
        guard case .active = state, let remaining = remainingTime, remaining <= 0 else { return }
        Log.info("CaffeinateService: deadline reached — ending session (OS process lagged the deadline)")
        // `state` is .active here, which (set together with `process` in start())
        // implies a non-nil `process`, so stop() takes its terminate branch and sets
        // `state = .idle` → `onStateChange` fires exactly once. Nothing more to do.
        stop()
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let proc = process else {
            if isActive { state = .idle }
            return
        }
        // Clear process reference first so terminationHandler becomes a no-op
        process = nil
        if proc.isRunning { proc.terminate() }
        state = .idle
    }

    /// Extends the active session by `interval` seconds without prompting.
    /// Composes start(duration:) — the running caffeinate process is replaced
    /// with one covering remaining + interval. No-op when idle or expired;
    /// the menu only offers Extend on an active session, so the guard is
    /// defensive.
    func extend(by interval: TimeInterval) {
        guard isActive, let remaining = remainingTime else { return }
        Log.info("CaffeinateService: extending by \(Int(interval))s (remaining \(Int(remaining))s)")
        start(duration: remaining + interval)
    }

    /// Called by AppDelegate on quit.
    func cleanup() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }
}
