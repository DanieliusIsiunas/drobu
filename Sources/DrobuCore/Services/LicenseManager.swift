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
public enum LicenseStatus: Equatable {
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
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            _ = SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }

    public func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        _ = SecItemDelete(query as CFDictionary)
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
        let iso = Self.isoFormatter.string(from: now())
        store.set(Self.trialStartKey, iso)
        recomputeStatus()
    }

    /// Verify a pasted license key and persist it on success.
    /// Throws on any failure; on success the published `status` flips
    /// to `.activated` synchronously.
    public func activate(keyString: String) throws {
        try verifyKey(keyString)
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
        if let activeKey = store.get(Self.activeLicenseKey),
           (try? verifyKey(activeKey)) != nil {
            status = .activated
            return
        }

        guard let startIso = store.get(Self.trialStartKey),
              let trialStart = Self.isoFormatter.date(from: startIso) else {
            // First launch hasn't been recorded yet. Treat as expired
            // so the gate is closed by default — `recordFirstLaunchIfNeeded`
            // flips it open on app startup.
            status = .trialExpired
            return
        }

        let expiresAt = trialStart.addingTimeInterval(Self.trialDuration)
        let secondsRemaining = expiresAt.timeIntervalSince(now())
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
