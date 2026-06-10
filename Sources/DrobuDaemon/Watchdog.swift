import Foundation

/// Fires once at the session deadline and invokes the reversal handler. The
/// daemon's guarantee that `pmset disablesleep` is reversed even if the client
/// crashes or is SIGKILL'd: the handler runs from the daemon's own timer, not
/// the client. Re-armable in place.
///
/// Each `arm()` bumps a generation counter captured into that timer's handler.
/// `DispatchSourceTimer.cancel()` does NOT retract a handler block that has
/// already been dispatched, so a timer that fired just before a re-arm could
/// otherwise reverse the *freshly re-armed* session. The handler passes its
/// firing generation back to the owner, which no-ops if it is stale (a re-arm
/// has since bumped the generation). All generation access happens under the
/// owner's lock (arm/cancel/currentGeneration are only called while held).
final class Watchdog {
    private let queue: DispatchQueue
    private let onFire: @Sendable (Int) -> Void
    private var timer: DispatchSourceTimer?
    private var generation = 0

    init(queue: DispatchQueue, onFire: @escaping @Sendable (Int) -> Void) {
        self.queue = queue
        self.onFire = onFire
    }

    /// The generation of the currently-armed timer (0 if never armed).
    var currentGeneration: Int { generation }

    /// Arm (or re-arm) to fire at `deadline`. A past deadline fires promptly.
    func arm(deadline: Date) {
        cancel()
        generation += 1
        let firingGeneration = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow), leeway: .seconds(1))
        let fire = onFire
        timer.setEventHandler { fire(firingGeneration) }
        self.timer = timer
        timer.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
