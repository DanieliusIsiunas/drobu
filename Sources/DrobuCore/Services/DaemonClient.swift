import Foundation
import DrobuShared

/// Result of a daemon `enable`.
struct EnableOutcome: Equatable, Sendable {
    let result: DaemonEnableResult
    let remaining: TimeInterval
}

/// Daemon `status()` reply (named struct rather than a tuple so it composes
/// cleanly through generic continuations).
struct DaemonStatusReply: Equatable, Sendable {
    let active: Bool
    let remaining: TimeInterval
}

/// Async façade over the daemon XPC connection. Injectable so `ClosedLidService`
/// is testable with a mock. A `nil` return means the daemon was unreachable
/// (connection error / interruption) — distinct from a daemon that replied.
protocol DaemonControlling: Sendable {
    func protocolVersion() async -> Int?
    func enable(durationSeconds: Int) async -> EnableOutcome?
    func disable() async -> Bool?
    /// One-shot display sleep on the lid-close edge. Best-effort: the panel is
    /// cosmetic relative to the stay-awake guarantee, so callers log a failure
    /// and move on — never unwind the session over it.
    func displayOff() async -> Bool?
    func status() async -> DaemonStatusReply?
    /// Bounded synchronous disable for the terminate path. The reply is
    /// delivered on a non-main queue, so a main-thread caller can block on the
    /// semaphore without deadlock (M7); a missed reply defers reversal to the
    /// daemon watchdog deadline.
    func disableBounded(timeout: TimeInterval) -> Bool
}

/// Resume a continuation exactly once, even if both the reply block and the
/// XPC error handler fire (NSXPC does not guarantee mutual exclusion).
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let body: @Sendable (T) -> Void
    init(_ body: @escaping @Sendable (T) -> Void) { self.body = body }
    func fire(_ value: T) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body(value) }
    }
}

/// Lock-guarded so a late XPC reply (after disableBounded's wait times out) and
/// the waiter's read don't race on the terminate path.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Owns the `NSXPCConnection(machServiceName:options:.privileged)` lifecycle:
/// lazy connect, pin the daemon via the Team-ID code-sign requirement,
/// nil-out on invalidation so the next call reconnects. Lock-guarded mutable
/// connection → `@unchecked Sendable`. This is daemon-client wiring verified
/// live in U7 (R12 keeps the XPC wire out of unit scope); ClosedLidService
/// tests drive a mock `DaemonControlling`.
final class DaemonClient: DaemonControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init() {}

    private func proxy(onError: @escaping @Sendable () -> Void) -> DrobuDaemonXPCProtocol? {
        lock.lock(); defer { lock.unlock() }
        let conn: NSXPCConnection
        if let existing = connection {
            conn = existing
        } else {
            let new = NSXPCConnection(machServiceName: DaemonConstants.machServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: DrobuDaemonXPCProtocol.self)
            // Pin the DAEMON's identity (distinct from the app's — M3). Using
            // the app requirement here would reject the genuine daemon and break
            // every call. (The daemon's listener pins the app id to verify us.)
            new.setCodeSigningRequirement(DaemonConstants.daemonCodeSigningRequirement)
            new.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.connection = nil; self.lock.unlock()
            }
            new.interruptionHandler = {
                Log.error("DaemonClient: XPC connection interrupted")
            }
            new.resume()
            connection = new
            conn = new
        }
        return conn.remoteObjectProxyWithErrorHandler { _ in onError() } as? DrobuDaemonXPCProtocol
    }

    func protocolVersion() async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let once = ResumeOnce<Int?> { continuation.resume(returning: $0) }
            guard let proxy = proxy(onError: { once.fire(nil) }) else { once.fire(nil); return }
            proxy.protocolVersion { version in once.fire(version) }
        }
    }

    func enable(durationSeconds: Int) async -> EnableOutcome? {
        await withCheckedContinuation { (continuation: CheckedContinuation<EnableOutcome?, Never>) in
            let once = ResumeOnce<EnableOutcome?> { continuation.resume(returning: $0) }
            guard let proxy = proxy(onError: { once.fire(nil) }) else { once.fire(nil); return }
            proxy.enable(durationSeconds: durationSeconds) { _, code, remaining in
                once.fire(EnableOutcome(result: DaemonEnableResult(rawValue: code) ?? .internalError,
                                        remaining: remaining))
            }
        }
    }

    func disable() async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let once = ResumeOnce<Bool?> { continuation.resume(returning: $0) }
            guard let proxy = proxy(onError: { once.fire(nil) }) else { once.fire(nil); return }
            proxy.disable { ok in once.fire(ok) }
        }
    }

    func displayOff() async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let once = ResumeOnce<Bool?> { continuation.resume(returning: $0) }
            guard let proxy = proxy(onError: { once.fire(nil) }) else { once.fire(nil); return }
            proxy.displayOff { ok in once.fire(ok) }
        }
    }

    func status() async -> DaemonStatusReply? {
        await withCheckedContinuation { (continuation: CheckedContinuation<DaemonStatusReply?, Never>) in
            let once = ResumeOnce<DaemonStatusReply?> { continuation.resume(returning: $0) }
            guard let proxy = proxy(onError: { once.fire(nil) }) else { once.fire(nil); return }
            proxy.status { active, remaining in once.fire(DaemonStatusReply(active: active, remaining: remaining)) }
        }
    }

    func disableBounded(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        guard let proxy = proxy(onError: { semaphore.signal() }) else { return false }
        proxy.disable { ok in
            box.value = ok
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value
    }
}
