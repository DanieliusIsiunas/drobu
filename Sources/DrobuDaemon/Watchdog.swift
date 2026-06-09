import Foundation

/// Fires once at the session deadline and invokes the reversal handler. The
/// daemon's guarantee that `pmset disablesleep` is reversed even if the client
/// crashes or is SIGKILL'd: the handler runs from the daemon's own timer, not
/// the client. Re-armable in place.
final class Watchdog {
    private let queue: DispatchQueue
    private let onFire: @Sendable () -> Void
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue, onFire: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onFire = onFire
    }

    /// Arm (or re-arm) to fire at `deadline`. A past deadline fires promptly.
    func arm(deadline: Date) {
        cancel()
        let interval = max(0, deadline.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, leeway: .seconds(1))
        let fire = onFire
        timer.setEventHandler { fire() }
        self.timer = timer
        timer.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
