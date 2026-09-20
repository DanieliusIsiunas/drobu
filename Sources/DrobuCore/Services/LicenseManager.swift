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
    /// Valid key, but the device-activation cap is full and this Mac is not one
    /// of the activated devices. Carries the active set for the remediation UI.
    /// Only reached once any trial has also expired.
    case activationLimitReached(devices: [ActivatedDevice])
    /// Valid key whose purchase was refunded (license_keys.refunded_at set).
    case licenseRevoked
}

public extension LicenseStatus {
    /// True when the floating panel + capture must be gated behind the
    /// `ActivationPanel`: the trial is over, the device cap is full, or the
    /// license was revoked. The single source of truth for both gates
    /// (`AppDelegate.showPanel()` and `CaptureUIPolicy.captureStartAllowed`),
    /// so a new state is never accidentally treated as permitted.
    var blocksUsage: Bool {
        switch self {
        case .trialActive, .activated:
            return false
        case .trialExpired, .activationLimitReached, .licenseRevoked:
            return true
        }
    }
}

/// The outcome of a store read, preserving the distinction the raw Keychain API
/// makes but `get -> String?` throws away:
/// `found` — a value is present and readable.
/// `absent` — a genuine miss (`errSecItemNotFound`): the item does not exist.
/// `denied` — the read failed for any reason OTHER than not-found (most
///   importantly `errSecAuthFailed` / `errSecInteractionNotAllowed`). The item
///   almost certainly EXISTS but is transiently unreadable (ACL/auth denial,
///   securityd hiccup). The status machine fails OPEN on `.denied` — only an
///   affirmative `.absent` gates. See `.claude/rules/keychain-and-crypto.md`.
public enum LicenseStoreRead: Equatable, Sendable {
    case found(String)
    case absent
    case denied
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
    /// Lossless read used by the gating paths so a transient Keychain denial is
    /// not mistaken for "no license". Defaulted below in terms of `get`, so a
    /// store that cannot distinguish denial (in-memory) never reports `.denied`.
    func read(_ key: String) -> LicenseStoreRead
}

public extension LicenseStore {
    func read(_ key: String) -> LicenseStoreRead {
        if let value = get(key) { return .found(value) }
        return .absent
    }
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
        if case .found(let value) = read(key) { return value }
        return nil
    }

    public func read(_ key: String) -> LicenseStoreRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let data = item as? Data
        switch Self.classify(status: status, hasData: data != nil) {
        case .value:
            guard let data, let string = String(data: data, encoding: .utf8) else {
                // Success with non-UTF8 bytes: readable but unusable. The item
                // exists, so this is `.denied` (fail open), never `.absent`.
                Log.error("KeychainLicenseStore: item for \(key) read OK but is not valid UTF-8 (\(data?.count ?? 0) bytes)")
                return .denied
            }
            return .found(string)
        case .absent:
            // notFound is the normal miss (every trial-mode recompute queries
            // active-license) — not signal, not logged.
            return .absent
        case .denied:
            // An ACL/auth denial is what gates a paying customer (the "Never
            // Deny" mode) — always signal. The status machine fails OPEN on it.
            Log.error("KeychainLicenseStore: SecItemCopyMatching denied for \(key): \(status) (\(Self.describe(status)))")
            return .denied
        }
    }

    /// Three-way classification of a `SecItemCopyMatching` result.
    /// `errSecSuccess` with data is the only `.value`; `errSecItemNotFound` is
    /// the only `.absent`; everything else — notably `errSecAuthFailed` (-25293)
    /// and `errSecInteractionNotAllowed` (-25308), and the anomalous
    /// success-without-data — is `.denied` (item likely exists, transiently
    /// unreadable). Pure, so it is unit-tested without touching the real Keychain.
    enum ReadOutcome: Equatable { case value, absent, denied }
    static func classify(status: OSStatus, hasData: Bool) -> ReadOutcome {
        switch status {
        case errSecSuccess:
            return hasData ? .value : .denied
        case errSecItemNotFound:
            return .absent
        default:
            return .denied
        }
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

    /// How long a positive activation verdict is trusted offline before a
    /// re-validation is attempted (R5). Generous so a no-Wi-Fi user is never
    /// inconvenienced; expiry only schedules a re-check — it never blocks
    /// (R6/KTD6: only an affirmative negative verdict blocks). Independent of
    /// `trialDuration`: the trial length is a marketing commitment, this is a
    /// network-tolerance budget — they happen to be equal today, don't couple them.
    public static let activationGracePeriod: TimeInterval = 14 * 24 * 60 * 60
    /// Shorter cadence for re-checking a NEGATIVE verdict (over_cap/revoked) so
    /// freeing a seat or reversing a refund unblocks quickly.
    public static let negativeRecheckCadence: TimeInterval = 60 * 60

    private static let trialStartKey = "trial-start"
    /// Monotonic clock anchor: the latest moment this manager has ever
    /// observed. Clamps trial math so rolling the system clock back
    /// cannot regain trial days. Maintained only in the trial branch —
    /// never read or written while `.activated` (no Keychain churn or
    /// ACL prompts for paying customers).
    private static let lastSeenKey = "last-seen"

    @Published public private(set) var status: LicenseStatus = .trialExpired

    /// Source of paid-entitlement truth for this build's distribution channel.
    /// The trial clock below is deliberately NOT delegated — it is identical on
    /// every channel, so keeping it here stops the two from forking.
    private let unlock: UnlockProviding
    private let store: LicenseStore
    private let now: () -> Date

    /// Designated init. `unlock` decides what "paid" means for this build
    /// (signed key + device cap on the direct channel; StoreKit entitlements on
    /// the Mac App Store), while this type owns the trial and composes the two
    /// into `status`.
    public init(
        unlock: UnlockProviding,
        store: LicenseStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.unlock = unlock
        self.store = store
        self.now = now
        unlock.onChange = { [weak self] in self?.recomputeStatus() }
        recomputeStatus()
    }

    /// Convenience init for the direct channel (and every existing test):
    /// builds a `DirectUnlockProvider` from the Ed25519 public key.
    /// `device`/`activationClient` are injected in tests with stubs so the IOKit
    /// read and the network stay out of scope.
    public convenience init(
        publicKey: Curve25519.Signing.PublicKey,
        store: LicenseStore,
        now: @escaping () -> Date = Date.init,
        device: DeviceIdentifying = SystemDeviceIdentity(),
        activationClient: DeviceActivationClient = HTTPDeviceActivationClient()
    ) {
        let provider = DirectUnlockProvider(
            publicKey: publicKey,
            store: store,
            now: now,
            device: device,
            activationClient: activationClient
        )
        self.init(unlock: provider, store: store, now: now)
    }

    /// The buyer email tied to the active license, if the channel supplies one.
    /// Powers the Settings "Licensed to {email}" row (R11).
    public var licensedEmail: String? { unlock.licensedEmail }

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
        switch store.read(Self.trialStartKey) {
        case .found:
            return   // trial already recorded
        case .denied:
            // A denied read means trial-start EXISTS but is transiently
            // unreadable (Keychain auth/ACL denial). Writing a fresh trial-start
            // now could overwrite the real one and reset the clock if the write
            // recovers before the read does — so do nothing and defer to a later
            // launch. recomputeStatus() already fails open in this window, so the
            // user is not gated meanwhile. See `.claude/rules/keychain-and-crypto.md`.
            Log.error("LicenseManager: trial-start read denied at first-launch check — not overwriting; deferring")
            return
        case .absent:
            break   // genuinely first launch — record it below
        }
        // The anchor can only legitimately exist after trial-start was
        // written, so finding it alone is tamper evidence (trial-start wiped).
        // A denied trial-start read no longer reaches here (handled above), so
        // this branch is now a true absence, not an ACL-denied read.
        if store.get(Self.lastSeenKey) != nil {
            Log.error("LicenseManager: last-seen present without trial-start — possible trial reset")
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

    /// Verify a pasted license key (offline) and register THIS device against
    /// the activation cap (online). Throws `LicenseError` only for a
    /// malformed/bad-signature key — that check is offline and fires before any
    /// network. The device-cap verdict never throws: it's returned so the caller
    /// can show feedback (success / over-cap / revoked) regardless of how
    /// `status` is masked — e.g. during an active trial a negative verdict is
    /// persisted but `status` stays `.trialActive`, so the caller must branch on
    /// the returned verdict, not on `status`. An unreachable backend fails OPEN
    /// (KTD5): stored optimistically, re-validation registers the device later.
    /// Returns `nil` when a newer mutation superseded this call (drop the result).
    @discardableResult
    public func activate(keyString: String) async throws -> ActivationVerdict? {
        defer { recomputeStatus() }
        return try await unlock.activate(keyString: keyString)
    }

    /// Free THIS Mac's seat on the server, then clear the local license so the
    /// seat is genuinely returned to the pool (R3). Distinct from `deactivate()`
    /// which is a local-only clear (support/testing) with no server call.
    ///
    /// Returns true when the seat was confirmed freed (and the local license
    /// cleared). If the server is unreachable / returns non-200, the local
    /// license is KEPT and false is returned: clearing it would strand the seat
    /// (still active server-side) with no local state to retry the release.
    @discardableResult
    public func deactivateThisDevice() async -> Bool {
        defer { recomputeStatus() }
        return await unlock.deactivateThisDevice()
    }

    /// Clear the active license + all device-activation cache (e.g. for support
    /// / testing). Status reverts to the underlying trial state.
    public func deactivate() {
        unlock.deactivateLocally()
        recomputeStatus()
    }

    /// Re-validate the stored license against the cap when the cached verdict is
    /// stale (positive past the grace window, or negative/unknown past the short
    /// cadence). Safe to call often — from the hourly refresh + on app
    /// activation. A no-op without a valid stored key, or when the cache is
    /// still fresh. An unreachable backend never downgrades a positive verdict
    /// (R6). Pass `force: true` for an explicit user action ("Check again") so
    /// it bypasses the cadence throttle — the throttle only paces background
    /// polling, never a deliberate tap.
    public func revalidateIfNeeded(force: Bool = false) async {
        defer { recomputeStatus() }
        await unlock.revalidateIfNeeded(force: force)
    }

    /// Force a status recomputation. Call from a periodic Timer so
    /// long-running sessions transition `trialActive(1)` → `trialExpired`
    /// at the actual day boundary, not on next interaction.
    public func refresh() {
        recomputeStatus()
    }

    // MARK: - Internal

    /// Recompute and publish. Assigns only on an actual change so the belt-and-braces
    /// recompute each public mutator performs (see below) costs no redundant SwiftUI
    /// invalidation when `onChange` already published the same result.
    ///
    /// Every public mutator recomputes after forwarding, rather than trusting the
    /// provider to have called `onChange`. `UnlockProviding` cannot enforce that call,
    /// and the whole point of the protocol is that a second conformer will exist — a
    /// conformer that persists an entitlement but misses one `onChange` on one branch
    /// would leave `status` stale until the hourly refresh, which is exactly the
    /// "correct on disk, still gated in the UI" shape this codebase has shipped before.
    /// Recomputing here is idempotent and makes that class of bug unreachable.
    private func recomputeStatus() {
        let next = computedStatus()
        guard next != status else { return }
        status = next
    }

    /// NOT pure: the `.none` and blocked branches run `trialStatus()`, which advances
    /// the clock-rollback anchor. The `.unlocked` / `.indeterminate` branches
    /// deliberately do not, so a paying customer's Keychain sees no anchor churn.
    private func computedStatus() -> LicenseStatus {
        switch unlock.currentState() {
        case .indeterminate:
            // FAIL OPEN. The entitlement could not be read (Keychain auth/ACL
            // denial). That is NOT evidence of "no license" — only `.none` is.
            // Never gate a (likely paying) user on data we couldn't read; treat
            // as activated until the read recovers.
            // See `.claude/rules/keychain-and-crypto.md`.
            return .activated
        case .unlocked:
            return .activated
        case .limitReached(let devices):
            // A blocked verdict must NOT degrade a still-running trial — prefer
            // the trial while days remain; only gate once it has also expired.
            return trialPreferredOver(.activationLimitReached(devices: devices))
        case .revoked:
            return trialPreferredOver(.licenseRevoked)
        case .none:
            // No entitlement (or a stored key that failed verification) — the
            // trial clock decides.
            return trialStatus()
        }
    }

    /// A blocked entitlement never cuts a running trial short: return the trial
    /// while it still has days left, otherwise the blocked status.
    private func trialPreferredOver(_ blocked: LicenseStatus) -> LicenseStatus {
        let trial = trialStatus()
        if case .trialActive = trial { return trial }
        return blocked
    }

    /// The trial state machine (clock-rollback anchor included). Extracted so
    /// the `.activated` happy path never touches the anchor (no Keychain churn
    /// for paying customers), while the no-key and blocked-but-trial paths reuse
    /// the exact same math.
    private func trialStatus() -> LicenseStatus {
        let startRead = store.read(Self.trialStartKey)
        if case .denied = startRead {
            // FAIL OPEN. trial-start exists (a trial was started) but is
            // transiently unreadable. Don't gate on an unreadable anchor —
            // grant a nominal active trial until the read recovers. No anchor
            // write here: reads/writes can't be trusted in this window. See
            // `.claude/rules/keychain-and-crypto.md`.
            Log.error("LicenseManager: trial-start read denied — failing open to a nominal active trial")
            return .trialActive(daysRemaining: 1)
        }
        guard case .found(let startIso) = startRead else {
            // `.absent`: first launch hasn't been recorded yet. Treat as expired
            // so the gate is closed by default — `recordFirstLaunchIfNeeded`
            // flips it open on app startup.
            return .trialExpired
        }
        guard let trialStart = Self.isoFormatter.date(from: startIso) else {
            // Non-nil but unparseable: permanently gated, because
            // recordFirstLaunchIfNeeded never overwrites a non-nil value.
            Log.error("LicenseManager: trial-start is unparseable — trial stays gated")
            return .trialExpired
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
            return .trialExpired
        }

        let expiresAt = trialStart.addingTimeInterval(Self.trialDuration)
        let secondsRemaining = expiresAt.timeIntervalSince(effectiveNow)
        if secondsRemaining > 0 {
            // Round up so "23 hours 59 minutes left" displays as 1 day.
            let daysRemaining = max(1, Int(ceil(secondsRemaining / 86400)))
            return .trialActive(daysRemaining: daysRemaining)
        }
        return .trialExpired
    }

    // MARK: - Helpers

    /// Shared with `DirectUnlockProvider`, which timestamps activation checks in
    /// the same format.
    static let isoFormatter: ISO8601DateFormatter = {
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
