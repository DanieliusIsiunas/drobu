import CryptoKit
import Foundation

/// Whether this Mac holds a usable paid entitlement — independent of *how* it
/// was bought. `LicenseManager` composes this with the trial clock to produce
/// the published `LicenseStatus`.
///
/// The direct channel answers from a signed license key plus the online device
/// cap; a future Mac App Store build answers from StoreKit entitlements. The
/// gate logic must not care which.
public enum UnlockState: Equatable, Sendable {
    /// No paid entitlement on this Mac — fall through to the trial clock.
    ///
    /// Deliberately NOT named `none`: stored in an `UnlockState?` (as a test
    /// double or a cached value naturally is), `= .none` silently resolves to
    /// `Optional.none` — i.e. nil — instead of this case, and the resulting
    /// no-op is invisible at the call site. That trap cost a wrong test result
    /// before the rename.
    case unlicensed
    /// Entitled and usable.
    case unlocked
    /// Entitlement exists but this Mac is over the device-activation cap.
    case limitReached(devices: [ActivatedDevice])
    /// Entitlement exists but the purchase was refunded / revoked.
    case revoked
    /// Could not be determined (e.g. a transient Keychain auth denial).
    ///
    /// **Callers MUST fail open.** An indeterminate read is not evidence of
    /// "no entitlement" — only `.none` is. Gating a likely-paying customer on
    /// data we could not read is the failure mode that produced the v1.10.1
    /// bug. See `.claude/rules/keychain-and-crypto.md`.
    ///
    /// **Conformers: this is a narrow state, not a general "I don't know".**
    /// Because callers grant full access on it, returning it too readily is a
    /// licence bypass. Return it ONLY when local, already-granted entitlement
    /// state exists but is temporarily unreadable. Do NOT return it because a
    /// remote service is unreachable: an offline App Store or activation backend
    /// is not evidence of a purchase, and treating it as one would unlock the app
    /// for someone who never bought it. The direct channel's unreachable-backend
    /// path deliberately keeps its **last known** verdict instead of reporting
    /// indeterminate — mirror that.
    case indeterminate
}

/// The source of paid-entitlement truth for one distribution channel.
///
/// Owns *all* purchase state for that channel — for the direct build that is
/// the license key plus the device-activation cache. It deliberately does NOT
/// own the trial clock: the trial is channel-agnostic and stays in
/// `LicenseManager`, so the two never fork.
@MainActor
public protocol UnlockProviding: AnyObject {
    /// Invoked after any change to entitlement state so the owner can
    /// recompute published status. Set by `LicenseManager`.
    var onChange: (() -> Void)? { get set }

    /// Current entitlement, read from local state only (no network).
    func currentState() -> UnlockState

    /// Buyer email, when the channel knows it. Powers "Licensed to {email}".
    var licensedEmail: String? { get }

    /// Redeem a license key. Direct-channel only; a channel without key entry
    /// throws `LicenseError.malformed` (its UI never offers the affordance).
    /// Returns `nil` when a newer mutation superseded this call.
    @discardableResult
    func activate(keyString: String) async throws -> ActivationVerdict?

    /// Release this Mac's seat server-side, then clear local entitlement.
    /// Returns false (keeping local state) if the release could not be confirmed.
    @discardableResult
    func deactivateThisDevice() async -> Bool

    /// Clear local entitlement without contacting the server (support/testing).
    func deactivateLocally()

    /// Re-check entitlement against its backing source when the cached answer
    /// is stale. `force` bypasses any throttle for a deliberate user action.
    func revalidateIfNeeded(force: Bool) async
}

/// Direct-channel entitlement: an offline-verified Ed25519 license key layered
/// with the online device-activation cap.
///
/// This is the pre-existing `LicenseManager` logic, moved wholesale so the gate
/// could become channel-agnostic. Behaviour is unchanged — the rules encoded
/// here (fail open on `.denied`, never downgrade a positive verdict when the
/// backend is unreachable, only an affirmative negative blocks) are
/// load-bearing and were each paid for with a shipped bug.
@MainActor
public final class DirectUnlockProvider: UnlockProviding {
    private static let activeLicenseKey = "active-license"
    // Device-activation cache (online cap layered over the offline key).
    private static let activationVerdictKey = "activation-verdict"      // activated|over_cap|revoked
    private static let activationCheckedAtKey = "activation-checked-at" // time of last DEFINITE verdict (drives grace/cadence)
    private static let activationAttemptedAtKey = "activation-attempted-at" // time of last attempt incl. unreachable (drives retry throttle)
    private static let activationDevicesKey = "activation-devices"      // JSON [ActivatedDevice]
    private static let activationEmailKey = "activation-email"          // "Licensed to {email}"

    /// How long a positive activation verdict is trusted offline before a
    /// re-validation is attempted (R5). Generous so a no-Wi-Fi user is never
    /// inconvenienced; expiry only schedules a re-check — it never blocks
    /// (R6/KTD6: only an affirmative negative verdict blocks). Independent of
    /// the trial length: that is a marketing commitment, this is a
    /// network-tolerance budget — they happen to be equal today, don't couple them.
    public static let activationGracePeriod: TimeInterval = 14 * 24 * 60 * 60
    /// Shorter cadence for re-checking a NEGATIVE verdict (over_cap/revoked) so
    /// freeing a seat or reversing a refund unblocks quickly.
    public static let negativeRecheckCadence: TimeInterval = 60 * 60

    public var onChange: (() -> Void)?

    private let publicKey: Curve25519.Signing.PublicKey
    private let store: LicenseStore
    private let now: () -> Date
    private let device: DeviceIdentifying
    private let activationClient: DeviceActivationClient

    /// Bumped by every user-initiated license mutation (activate / deactivate /
    /// deactivateThisDevice). An in-flight `activate` captures it before its
    /// `await` and drops its result if a newer mutation superseded it — so a
    /// slow response from one surface can't clobber a newer key from another.
    /// (Catches a SYNCHRONOUS local `deactivateLocally()` landing during a network op.)
    private var activationGeneration = 0
    /// Tail of the serial activation channel. Every network op (activate /
    /// revalidate / deactivateThisDevice) awaits the previous one before its own
    /// request, so two never overlap on the wire — a `deactivate` can't race an
    /// in-flight `activate`, which would otherwise let a late activate RPC
    /// re-claim a seat the user just released (and a revalidate queued after a
    /// deactivate re-reads the now-cleared key and no-ops).
    private var activationTail: Task<Void, Never>?

    /// Reference box so a serialized op can hand its result back to the awaiting
    /// caller. Touched only on the MainActor; @unchecked silences the Sendable
    /// capture check for the MainActor-isolated channel task.
    private final class Box<T>: @unchecked Sendable { var value: T? }

    public init(
        publicKey: Curve25519.Signing.PublicKey,
        store: LicenseStore,
        now: @escaping () -> Date = Date.init,
        device: DeviceIdentifying = SystemDeviceIdentity(),
        activationClient: DeviceActivationClient = HTTPDeviceActivationClient()
    ) {
        self.publicKey = publicKey
        self.store = store
        self.now = now
        self.device = device
        self.activationClient = activationClient
    }

    /// Enqueue `work` behind the current channel tail; returns a task the caller
    /// awaits. `work` runs only after the prior op fully completes.
    private func chain(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = activationTail
        let task = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
        activationTail = task
        return task
    }

    // MARK: - UnlockProviding

    public var licensedEmail: String? { store.get(Self.activationEmailKey) }

    public func currentState() -> UnlockState {
        switch store.read(Self.activeLicenseKey) {
        case .denied:
            // The item EXISTS but is transiently unreadable (Keychain auth/ACL
            // denial). NOT evidence of "no license" — the caller fails open.
            return .indeterminate
        case .found(let activeKey):
            do {
                try verifyKey(activeKey)
            } catch {
                // A stored key that reads but fails verification is the one
                // gated-paying-customer case OSStatus logging alone misses
                // (bitrot, truncated write, public-key change). Never log the
                // key material itself — the error carries no key bytes.
                Log.error("DirectUnlockProvider: stored active-license failed verification (\(error)) — falling back to trial state")
                return .unlicensed
            }
            // Map the cached device-cap verdict. A positive OR absent verdict is
            // usable (absent = grandfathered/optimistic — R7/KTD6: only an
            // affirmative negative blocks; the grace window + fail-open keep a
            // valid key working). Re-validation refreshes the verdict over time.
            switch store.get(Self.activationVerdictKey) {
            case "over_cap": return .limitReached(devices: storedDevices())
            case "revoked": return .revoked
            default: return .unlocked
            }
        case .absent:
            return .unlicensed
        }
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
        try verifyKey(keyString)   // sync; throws before queueing on the channel
        let box = Box<ActivationVerdict>()
        await chain { [weak self] in
            guard let self else { return }
            self.activationGeneration += 1
            let generation = self.activationGeneration
            // keyString is the customer's license key — never logged (see
            // KeychainLicenseStore.set / DeviceActivationClient). The stale-verdict
            // clear for a replacement key happens INSIDE persistVerdict (atomically
            // with storing the new key), NOT before the await — clearing it now
            // would leave a window where active-license still points at the old key
            // with no verdict, reading as optimistic .unlocked if a refresh/crash
            // lands mid-flight (it could resurrect a blocked/refunded license).
            let verdict = await self.activationClient.activate(
                key: keyString,
                deviceHash: self.device.deviceHash,
                deviceName: self.device.deviceName
            )
            // A synchronous local deactivate landed during the await — its
            // result is canonical; drop this stale one rather than clobbering it.
            guard generation == self.activationGeneration else { return }
            self.persistVerdict(verdict, key: keyString)
            self.onChange?()
            box.value = verdict
        }.value
        return box.value
    }

    /// Free THIS Mac's seat on the server, then clear the local license so the
    /// seat is genuinely returned to the pool (R3). Distinct from
    /// `deactivateLocally()` which has no server call.
    ///
    /// Returns true when the seat was confirmed freed (and the local license
    /// cleared). If the server is unreachable / returns non-200, the local
    /// license is KEPT and false is returned: clearing it would strand the seat
    /// (still active server-side) with no local state to retry the release.
    @discardableResult
    public func deactivateThisDevice() async -> Bool {
        let box = Box<Bool>()
        await chain { [weak self] in
            guard let self else { return }
            // Re-read the key INSIDE the channel (a prior op may have changed it).
            guard let key = self.store.get(Self.activeLicenseKey) else {
                box.value = true   // nothing to release
                return
            }
            // Supersede any in-flight/queued activate so its result can't re-store
            // the key we're about to release.
            self.activationGeneration += 1
            let freed = await self.activationClient.deactivate(key: key, deviceHash: self.device.deviceHash)
            if freed { self.deactivateLocally() }
            box.value = freed
        }.value
        return box.value ?? true
    }

    /// Clear the active license + all device-activation cache (e.g. for support
    /// / testing). The owner's status reverts to the underlying trial state.
    public func deactivateLocally() {
        activationGeneration += 1   // supersede any in-flight activate/revalidate
        store.delete(Self.activeLicenseKey)
        clearActivationCache()
        onChange?()
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
        await chain { [weak self] in
            guard let self else { return }
            // All checks INSIDE the channel: a revalidate queued behind a
            // deactivate re-reads the now-cleared key and no-ops; one queued
            // behind another revalidate sees the refreshed timestamp and skips.
            guard let key = self.store.get(Self.activeLicenseKey),
                  (try? self.verifyKey(key)) != nil else { return }
            guard force || self.shouldRevalidate() else { return }
            let verdict = await self.activationClient.activate(
                key: key,
                deviceHash: self.device.deviceHash,
                deviceName: self.device.deviceName
            )
            // Defensive: if the stored key changed during the await (a sync
            // local deactivate), drop the stale result rather than resurrecting
            // the old key/verdict.
            guard self.store.get(Self.activeLicenseKey) == key else { return }
            self.persistVerdict(verdict, key: key)
            self.onChange?()
        }.value
    }

    // MARK: - Device activation cache

    /// Drop the cached activation verdict/devices/email/timestamp (but NOT the
    /// license key). Used on a key change and as part of a full deactivate.
    private func clearActivationCache() {
        store.delete(Self.activationVerdictKey)
        store.delete(Self.activationCheckedAtKey)
        store.delete(Self.activationAttemptedAtKey)
        store.delete(Self.activationDevicesKey)
        store.delete(Self.activationEmailKey)
    }

    /// Persist a server verdict. The key is (re)stored on every definite verdict
    /// so an over_cap/revoked state survives relaunch (and self-heals on the
    /// next re-validation). `.unreachable` fails OPEN and records only the
    /// ATTEMPT time (never the verdict-time): the grant stays optimistic, an
    /// existing positive verdict is never downgraded (R6), and — critically — a
    /// transient outage does NOT renew the positive grace window.
    private func persistVerdict(_ verdict: ActivationVerdict, key: String) {
        // Replacement key: the cached verdict/devices/email belong to the OLD
        // key — drop them so the new key doesn't inherit a stale over_cap/revoked
        // block (esp. on the .unreachable path, which doesn't set a fresh
        // verdict). Done here, synchronously, atomic with storing the new key
        // below — no await in this method, so there's never a window where
        // active-license points at a key whose verdict was already cleared.
        if store.get(Self.activeLicenseKey) != key {
            clearActivationCache()
        }
        let nowIso = LicenseManager.isoFormatter.string(from: now())
        // Every attempt records attempted-at (drives the unreachable/negative
        // retry throttle). Only a DEFINITE verdict records checked-at (drives
        // the positive grace + negative cadence) — so an unreachable attempt
        // can't postpone the next real check.
        store.set(Self.activationAttemptedAtKey, nowIso)
        switch verdict {
        case .activated(let email):
            store.set(Self.activeLicenseKey, key)
            store.set(Self.activationVerdictKey, "activated")
            store.set(Self.activationCheckedAtKey, nowIso)
            store.delete(Self.activationDevicesKey)
            if let email, !email.isEmpty { store.set(Self.activationEmailKey, email) }
        case .overCap(let devices):
            store.set(Self.activeLicenseKey, key)
            store.set(Self.activationVerdictKey, "over_cap")
            store.set(Self.activationCheckedAtKey, nowIso)
            storeDevices(devices)
        case .revoked:
            store.set(Self.activeLicenseKey, key)
            store.set(Self.activationVerdictKey, "revoked")
            store.set(Self.activationCheckedAtKey, nowIso)
        case .unreachable:
            // Key kept (fail open); attempted-at recorded above for throttling.
            // checked-at + verdict deliberately untouched: the positive grace is
            // measured from the last DEFINITE verdict, never renewed by an outage.
            store.set(Self.activeLicenseKey, key)
        }
    }

    /// Decide whether to re-contact the server. Two clocks:
    ///   * checked-at (last definite verdict) → positive grace / negative cadence.
    ///   * attempted-at (last attempt incl. unreachable) → retry throttle once
    ///     the verdict is stale or absent, so a persistent outage re-checks on
    ///     the short cadence rather than on every app focus.
    private func shouldRevalidate() -> Bool {
        // A still-fresh definite verdict short-circuits (no re-contact).
        if let checkedIso = store.get(Self.activationCheckedAtKey),
           let checkedAt = LicenseManager.isoFormatter.date(from: checkedIso) {
            let age = now().timeIntervalSince(checkedAt)
            if store.get(Self.activationVerdictKey) == "activated" {
                if age < Self.activationGracePeriod { return false }
            } else if age < Self.negativeRecheckCadence {
                return false
            }
        }
        // Verdict stale or absent (grandfather/optimistic): re-check, but
        // throttle repeated attempts (esp. while unreachable) to the short cadence.
        if let attemptedIso = store.get(Self.activationAttemptedAtKey),
           let attemptedAt = LicenseManager.isoFormatter.date(from: attemptedIso) {
            return now().timeIntervalSince(attemptedAt) >= Self.negativeRecheckCadence
        }
        return true
    }

    private func storeDevices(_ devices: [ActivatedDevice]) {
        guard let data = try? JSONEncoder().encode(devices),
              let json = String(data: data, encoding: .utf8) else {
            store.delete(Self.activationDevicesKey)
            return
        }
        store.set(Self.activationDevicesKey, json)
    }

    private func storedDevices() -> [ActivatedDevice] {
        guard let json = store.get(Self.activationDevicesKey),
              let data = json.data(using: .utf8),
              let devices = try? JSONDecoder().decode([ActivatedDevice].self, from: data) else {
            return []
        }
        return devices
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
        guard let payload = LicenseManager.base64URLDecode(String(parts[0])),
              let signature = LicenseManager.base64URLDecode(String(parts[1])) else {
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
}
