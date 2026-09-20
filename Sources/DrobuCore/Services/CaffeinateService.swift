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

    /// Holds the OS power assertions for the duration of a session. Injected so
    /// the state machine can be tested without touching real power management.
    private let assertion: PowerAssertionHolding

    /// One-shot timer that ends the session at its logical deadline, so `state`
    /// (and the menu-bar badge, which is driven off `onStateChange`) clear on time.
    /// The assertions also carry a kernel-enforced timeout, but that only stops the
    /// Mac being held awake — it does not notify us, so this timer remains the thing
    /// that keeps `state`, `isActive`, and the badge in agreement.
    private var expiryTimer: Timer?

    init(assertion: PowerAssertionHolding = IOPMPowerAssertion()) {
        self.assertion = assertion
    }

    var isActive: Bool {
        guard case .active(_, _) = state else { return false }
        // Treat as inactive once remaining time has elapsed, even if the session
        // has not been torn down yet.
        if let remaining = remainingTime, remaining <= 0 { return false }
        return true
    }

    var remainingTime: TimeInterval? {
        guard case .active(let startDate, let duration) = state else { return nil }
        let remaining = startDate.addingTimeInterval(duration).timeIntervalSinceNow
        return max(0, remaining)
    }

    func start(duration: TimeInterval) {
        // Drop any previous session's assertions + pending expiry first.
        assertion.release()
        expiryTimer?.invalidate()
        expiryTimer = nil

        // A non-positive duration is already expired by wall-clock math, so there
        // is nothing to hold the Mac awake *for*. Still open the session so the
        // state machine behaves uniformly (`isActive` reports false via the
        // wall-clock check, and the deadline path tears it down).
        if duration > 0 {
            guard assertion.hold(duration: duration, reason: "Drobu Keep Awake") else {
                Log.error("CaffeinateService: power assertion refused — not entering active state")
                setIdle()
                return
            }
        }

        state = .active(startDate: Date(), duration: duration)
        scheduleExpiry(after: duration)
    }

    /// Schedule the deadline check. The menu-bar badge is driven by `state`
    /// transitions (`onStateChange`), and nothing else flips `state` back to
    /// `.idle` when a session simply runs out. Without this, the "keep awake" dot
    /// persists after the session has expired. `.common` mode so it still fires
    /// while an NSMenu is tracking (default-mode timers don't — the ClipboardMonitor
    /// idiom); a one-shot whose fire date passed during sleep fires on wake, which
    /// is exactly when we want to reconcile.
    private func scheduleExpiry(after duration: TimeInterval) {
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0, duration), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileExpiry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Idempotent deadline reconciliation: if the session reached its deadline but
    /// `state` is still `.active`, end it now so `state`, `isActive`, and the badge
    /// all agree. No-op unless active-and-expired, so it is safe to call any time
    /// (timer fire or a wake re-check). Mirrors `ClosedLidService.reconcileTick`.
    func reconcileExpiry() {
        guard case .active = state, let remaining = remainingTime, remaining <= 0 else { return }
        Log.info("CaffeinateService: deadline reached — ending session")
        stop()
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        assertion.release()
        setIdle()
    }

    /// Transition to `.idle` only when not already there, so `onStateChange` — and
    /// therefore the menu-bar badge refresh — fires exactly once per session end.
    private func setIdle() {
        guard state != .idle else { return }
        state = .idle
    }

    /// Extends the active session by `interval` seconds without prompting.
    /// Composes start(duration:) — the held assertions are replaced with ones
    /// covering remaining + interval. No-op when idle or expired; the menu only
    /// offers Extend on an active session, so the guard is defensive.
    func extend(by interval: TimeInterval) {
        guard isActive, let remaining = remainingTime else { return }
        Log.info("CaffeinateService: extending by \(Int(interval))s (remaining \(Int(remaining))s)")
        start(duration: remaining + interval)
    }

    /// Called by AppDelegate on quit.
    func cleanup() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        assertion.release()
    }
}
