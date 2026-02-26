import Foundation

@MainActor
final class CaffeinateService {
    enum State: Equatable {
        case idle
        case active(startDate: Date, duration: TimeInterval)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Callback for state changes — set by AppDelegate to update menu bar badge.
    var onStateChange: ((State) -> Void)?

    private var process: Process?

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    var remainingTime: TimeInterval? {
        guard case .active(let startDate, let duration) = state else { return nil }
        let remaining = startDate.addingTimeInterval(duration).timeIntervalSinceNow
        return max(0, remaining)
    }

    func start(duration: TimeInterval) {
        // Kill existing process first
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-dims", "-t", "\(Int(duration))"]

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.state = .idle
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            state = .active(startDate: Date(), duration: duration)
        } catch {
            NSLog("CaffeinateService: failed to launch caffeinate: \(error)")
            state = .idle
            process = nil
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            if isActive { state = .idle }
            return
        }
        proc.terminate()
        process = nil
        state = .idle
    }

    /// Called by AppDelegate on quit.
    func cleanup() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }
}
