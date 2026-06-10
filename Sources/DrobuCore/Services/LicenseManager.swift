import CryptoKit
import Foundation
import Security

/// Coarse-grained state of the license / trial system.
///
/// `trialActive(daysRemaining:)` — first-launch happened within the
///   last 14 days. `daysRemaining` is the integer count UIs should
///   display ("3 days remaining"). Always >= 1 while active.
/// `trialExpired` — 14 days have elapsed since first launch and no
///   valid license key has been activated. The UI should hard-gate
///   the floating panel in this state.
/// `activated` — a valid license key is stored. The trial timer is
///   irrelevant. Always wins over the trial state.
public enum LicenseStatus: Equatable, Sendable {
    case trialActive(daysRemaining: Int)
    case trialExpired
    case activated
}

/// Minimal key-value store the LicenseManager uses to persist the
/// trial-start timestamp and the active license key. Production uses
/// `KeychainLicenseStore`; tests inject `InMemoryLicenseStore` so
/// they never touch the real Keychain (which would require
/// entitlements / interactive auth on CI).
public protocol LicenseStore {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func delete(_ key: String)
}

/// Keychain-backed store. One generic-password entry per (service, key)
/// tuple. The service name is shared; the per-call `key` becomes the
/// account attribute so each entry is independently fetchable.
public struct KeychainLicenseStore: LicenseStore {
    public let service: String

    public init(service: String = "com.danielius.ClipboardHistory.license") {
        self.service = service
    }

    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            // notFound is the normal miss (every trial-mode recompute queries
            // active-license) — only real denials are signal. An ACL denial
            // here is what gates a paying customer (the "Never Deny" mode).
            if status != errSecItemNotFound {
                Log.error("KeychainLicenseStore: SecItemCopyMatching failed for \(key): \(status) (\(Self.describe(status)))")
            }
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            Log.error("KeychainLicenseStore: item for \(key) read OK but is not valid UTF-8 (\(data.count) bytes)")
            return nil
        }
        return string
    }

    public func set(_ key: String, _ value: String) {
        // `value` is secret on the active-license path (the raw license key)
        // — it must never appear in any log interpolation below.
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            status = SecItemAdd(insertQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Two app instances raced past the not-found check — the
                // item exists now, so this is a benign race, not corruption.
                status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            }
        }
        if status != errSecSuccess {
            Log.error("KeychainLicenseStore: write failed for \(key): \(status) (\(Self.describe(status)))")
        }
    }

    public func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.error("KeychainLicenseStore: SecItemDelete failed for \(key): \(status) (\(Self.describe(status)))")
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
    }
}

/// In-memory store for tests. Never persists.
public final class InMemoryLicenseStore: LicenseStore {
    private var storage: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { storage[key] }
    public func set(_ key: String, _ value: String) { storage[key] = value }
    public func delete(_ key: String) { storage.removeValue(forKey: key) }
}

/// Drives the trial countdown and license verification.
///
/// Status changes are published so SwiftUI views bind to it. The status
/// is recomputed every time `refresh()` is called and on every mutation
/// (`recordFirstLaunchIfNeeded`, `activate`, `deactivate`). A periodic
/// caller (e.g. an hourly Timer in AppDelegate) keeps the daysRemaining
/// value fresh for long-running sessions that cross day boundaries.
@MainActor
public final class LicenseManager: ObservableObject {
    /// 14 days in seconds. Matches the website's advertised trial.
    public static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    private static let trialStartKey = "trial-start"
    private static let activeLicenseKey = "active-license"
    /// Monotonic clock anchor: the latest moment this manager has ever
    /// observed. Clamps trial math so rolling the system clock back
    /// cannot regain trial days. Maintained only in the trial branch —
    /// never read or written while `.activated` (no Keychain churn or
    /// ACL prompts for paying customers).
    private static let lastSeenKey = "last-seen"

    @Published public private(set) var status: LicenseStatus = .trialExpired

    private let publicKey: Curve25519.Signing.PublicKey
    private let store: LicenseStore
    private let now: () -> Date

    /// Designated init for production code (and any caller with an
    /// already-loaded public key).
    public init(
        publicKey: Curve25519.Signing.PublicKey,
        store: LicenseStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.publicKey = publicKey
        self.store = store
        self.now = now
        recomputeStatus()
    }

    /// Convenience: read the embedded public key from `Info.plist` and
    /// use the Keychain store. Throws `LicenseError.publicKeyMissing`
    /// if the key isn't present or is unparseable — that's a build/dev
    /// error, not something to swallow.
    public static func production() throws -> LicenseManager {
        let key = try loadEmbeddedPublicKey()
        return LicenseManager(publicKey: key, store: KeychainLicenseStore())
    }

    /// App-wide shared instance. Used by AppDelegate (panel gate, hourly
    /// refresh) and by SettingsView (License section), which cannot
    /// reach AppDelegate via `NSApp.delegate` because the Settings scene
    /// runs under a different activation policy. Initialization failures
    /// crash on purpose — a missing public key indicates a build defect
    /// that must be surfaced loudly, not papered over.
    public static let shared: LicenseManager = {
        do {
            return try production()
        } catch {
            fatalError("LicenseManager.shared failed to initialize: \(error). The Info.plist DrobuLicensePublicKey entry is missing or malformed.")
        }
    }()

    /// Idempotent: records the first-launch timestamp the first time
    /// it's called; no-op on subsequent calls. AppDelegate should call
    /// this once during `applicationDidFinishLaunching`.
    public func recordFirstLaunchIfNeeded() {
        guard store.get(Self.trialStartKey) == nil else { return }
        // The anchor can only legitimately exist after trial-start was
        // written, so finding it alone is tamper evidence (trial-start
        // wiped) — but a Keychain-ACL-denied read of trial-start looks
        // identical, so log and proceed with the fresh trial rather than
        // failing closed and bricking a real user.
        if store.get(Self.lastSeenKey) != nil {
            Log.error("LicenseManager: last-seen present without trial-start — possible trial reset (or ACL-denied read)")
        }
        let iso = Self.isoFormatter.string(from: now())
        store.set(Self.trialStartKey, iso)
        // Read-back: a silently failed Keychain write here means the user
        // sees "trial ended" on day 0. The failure happens at launch, so
        // this line is always in the current session's truncate-on-launch
        // log — the smoking gun for that support-ticket shape.
        if store.get(Self.trialStartKey) == nil {
            Log.error("LicenseManager: trial-start write did not persist (read-back nil) — user will be gated")
        }
        recomputeStatus()
    }

    /// Verify a pasted license key and persist it on success.
    /// Throws on any failure; on success the published `status` flips
    /// to `.activated` synchronously.
    public func activate(keyString: String) throws {
        try verifyKey(keyString)
        // keyString is the customer's license key — the store must never
        // log this value (see KeychainLicenseStore.set).
        store.set(Self.activeLicenseKey, keyString)
        recomputeStatus()
    }

    /// Clear the active license (e.g. for support / testing).
    /// Status reverts to the underlying trial state.
    public func deactivate() {
        store.delete(Self.activeLicenseKey)
        recomputeStatus()
    }

    /// Force a status recomputation. Call from a periodic Timer so
    /// long-running sessions transition `trialActive(1)` → `trialExpired`
    /// at the actual day boundary, not on next interaction.
    public func refresh() {
        recomputeStatus()
    }

    // MARK: - Internal

    private func recomputeStatus() {
        // Activated wins regardless of trial state.
        if let activeKey = store.get(Self.activeLicenseKey) {
            do {
                try verifyKey(activeKey)
                status = .activated
                return
            } catch {
                // A stored key that reads but fails verification is the one
                // gated-paying-customer case OSStatus logging alone misses
                // (bitrot, truncated write, public-key change). Never log
                // the key material itself — the error case carries no key
                // bytes.
                Log.error("LicenseManager: stored active-license failed verification (\(error)) — falling back to trial state")
            }
        }

        guard let startIso = store.get(Self.trialStartKey) else {
            // First launch hasn't been recorded yet. Treat as expired
            // so the gate is closed by default — `recordFirstLaunchIfNeeded`
            // flips it open on app startup.
            status = .trialExpired
            return
        }
        guard let trialStart = Self.isoFormatter.date(from: startIso) else {
            // Non-nil but unparseable: permanently gated, because
            // recordFirstLaunchIfNeeded never overwrites a non-nil value.
            Log.error("LicenseManager: trial-start is unparseable — trial stays gated")
            status = .trialExpired
            return
        }

        // Clock-rollback anchor: clamp the effective clock to the latest
        // moment ever observed, so setting the clock back never regains
        // trial days. An unparseable anchor is treated as missing and
        // overwritten with a valid value below (self-heal).
        let rawNow = now()
        var anchor: Date?
        if let anchorIso = store.get(Self.lastSeenKey) {
            anchor = Self.isoFormatter.date(from: anchorIso)
            if anchor == nil {
                Log.error("LicenseManager: last-seen anchor is unparseable — resetting it")
            }
        }
        let effectiveNow = max(rawNow, anchor ?? rawNow)
        if let anchor, rawNow < anchor {
            Log.info("LicenseManager: clock rollback clamped (now \(Self.isoFormatter.string(from: rawNow)) < last-seen \(Self.isoFormatter.string(from: anchor)))")
        }
        if anchor.map({ effectiveNow > $0 }) ?? true {
            store.set(Self.lastSeenKey, Self.isoFormatter.string(from: effectiveNow))
        }

        // Future-dated trialStart fails closed but self-heals: the trial
        // activates with its full window once the real clock passes it.
        // The anchor was persisted above, so forward observations are
        // recorded even while gated.
        if trialStart > effectiveNow {
            Log.error("LicenseManager: trial-start is in the future — gated until the clock catches up")
            status = .trialExpired
            return
        }

        let expiresAt = trialStart.addingTimeInterval(Self.trialDuration)
        let secondsRemaining = expiresAt.timeIntervalSince(effectiveNow)
        if secondsRemaining > 0 {
            // Round up so "23 hours 59 minutes left" displays as 1 day.
            let daysRemaining = max(1, Int(ceil(secondsRemaining / 86400)))
            status = .trialActive(daysRemaining: daysRemaining)
        } else {
            status = .trialExpired
        }
    }

    private func verifyKey(_ keyString: String) throws {
        // Expected format: DROBU-<base64url(payload)>.<base64url(signature)>
        guard keyString.hasPrefix("DROBU-") else {
            throw LicenseError.malformed
        }
        let body = keyString.dropFirst("DROBU-".count)
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw LicenseError.malformed
        }
        guard let payload = Self.base64URLDecode(String(parts[0])),
              let signature = Self.base64URLDecode(String(parts[1])) else {
            throw LicenseError.malformed
        }
        // Structural length checks: Ed25519 signatures are exactly 64 bytes
        // and the issuer always uses 32-byte payloads. Anything else is
        // malformed input, not a "real attempt that failed to verify".
        guard signature.count == 64, !payload.isEmpty else {
            throw LicenseError.malformed
        }
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw LicenseError.badSignature
        }
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Decode the URL-safe base64 dialect used by issue-license-key.sh.
    /// Differs from standard base64: `+` → `-`, `/` → `_`, no `=` padding.
    static func base64URLDecode(_ s: String) -> Data? {
        var normalized = s.replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 so Foundation's decoder accepts it.
        while normalized.count % 4 != 0 { normalized += "=" }
        return Data(base64Encoded: normalized)
    }

    /// Public-key fetch for the production initializer. Exposed for
    /// callers that want to surface `publicKeyMissing` differently.
    public static func loadEmbeddedPublicKey() throws -> Curve25519.Signing.PublicKey {
        guard let b64 = Bundle.main.infoDictionary?["DrobuLicensePublicKey"] as? String,
              let data = Data(base64Encoded: b64),
              data.count == 32 else {
            throw LicenseError.publicKeyMissing
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}
