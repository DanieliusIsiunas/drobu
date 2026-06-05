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
        // Kill existing process first (without terminationHandler race)
        if let old = process, old.isRunning {
            old.terminate()
        }
        process = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-dims", "-t", "\(Int(duration))"]

        // Only reset state if this process is still the current one.
        // This prevents a terminated old process from clobbering a new session.
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self, self.process === terminatedProcess else { return }
                self.state = .idle
                self.process = nil
            }
        }

        do {
            try proc.run()
            Log.debug("CaffeinateService: launched caffeinate pid=\(proc.processIdentifier), duration=\(Int(duration))s")
            process = proc
            state = .active(startDate: Date(), duration: duration)
        } catch {
            Log.error("CaffeinateService: failed to launch caffeinate: \(error)")
            state = .idle
            process = nil
        }
    }

    func stop() {
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
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }
}
