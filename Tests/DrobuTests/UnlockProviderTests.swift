import Testing
import Foundation
import CryptoKit
@testable import DrobuCore

/// Stands in for a distribution channel's entitlement source so the gate's
/// composition rules can be tested without any key, Keychain, or network.
@MainActor
final class FakeUnlockProvider: UnlockProviding {
    var onChange: (() -> Void)?
    var state: UnlockState
    var licensedEmail: String?
    private(set) var revalidateCount = 0
    private(set) var lastRevalidateForced: Bool?
    private(set) var deactivateLocallyCount = 0
    private(set) var deactivateThisDeviceCount = 0
    private(set) var activateCount = 0

    init(state: UnlockState = .unlicensed) {
        self.state = state
    }

    func currentState() -> UnlockState { state }

    /// Simulate the channel learning something new (a server verdict, a StoreKit
    /// transaction update) and notifying its owner.
    func emit(_ newState: UnlockState) {
        state = newState
        onChange?()
    }

    func activate(keyString: String) async throws -> ActivationVerdict? {
        activateCount += 1
        if let silent = silentStateOnActivate {
            state = silent          // deliberately WITHOUT onChange
            silentStateOnActivate = nil
        }
        return nil
    }

    func deactivateThisDevice() async -> Bool {
        deactivateThisDeviceCount += 1
        if let silent = silentStateOnDeactivateDevice {
            state = silent          // deliberately WITHOUT onChange
            silentStateOnDeactivateDevice = nil
        }
        return true
    }

    func deactivateLocally() {
        deactivateLocallyCount += 1
        state = .unlicensed
        onChange?()
    }

    func revalidateIfNeeded(force: Bool) async {
        revalidateCount += 1
        lastRevalidateForced = force
        if let silent = silentStateOnRevalidate {
            state = silent          // deliberately WITHOUT onChange
            silentStateOnRevalidate = nil
        }
    }

    /// When set, the next `activate`/`deactivateThisDevice`/`revalidateIfNeeded`
    /// mutates `state` and deliberately does NOT call `onChange` — modelling a
    /// conformer that forgets to notify. Used to pin `LicenseManager`'s defensive
    /// recompute-after-forwarding.
    var silentStateOnActivate: UnlockState?
    var silentStateOnDeactivateDevice: UnlockState?
    var silentStateOnRevalidate: UnlockState?
}

/// The channel-agnostic half of the gate: how a paid entitlement composes with
/// the trial clock. `LicenseManagerTests` covers the direct channel's own rules
/// (key verification, device cap, grace windows); this suite pins the mapping
/// that any future channel — notably a Mac App Store StoreKit provider — must
/// satisfy.
@Suite("UnlockProvider composition")
@MainActor
struct UnlockProviderTests {

    /// Manager whose trial began `daysAgo` days ago. `daysAgo: nil` means the
    /// trial was never started (the pre-`recordFirstLaunchIfNeeded` state).
    private func makeManager(
        unlock: FakeUnlockProvider,
        trialStartedDaysAgo daysAgo: Double?
    ) -> LicenseManager {
        let store = InMemoryLicenseStore()
        let now = Date()
        if let daysAgo {
            let start = now.addingTimeInterval(-daysAgo * 86400)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            store.set("trial-start", formatter.string(from: start))
        }
        return LicenseManager(unlock: unlock, store: store, now: { now })
    }

    // MARK: - Entitlement wins over the trial

    @Test func unlockedReportsActivated() {
        let fake = FakeUnlockProvider(state: .unlocked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)   // long expired
        #expect(mgr.status == .activated)
        #expect(!mgr.status.blocksUsage)
    }

    /// FAIL OPEN. An unreadable entitlement (transient Keychain auth/ACL denial)
    /// must never gate a likely-paying customer — this is the v1.10.1 contract,
    /// and it has to survive the move behind `UnlockProviding`.
    /// See `.claude/rules/keychain-and-crypto.md`.
    @Test func indeterminateFailsOpenToActivated() {
        let fake = FakeUnlockProvider(state: .indeterminate)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)   // long expired
        #expect(mgr.status == .activated)
        #expect(!mgr.status.blocksUsage)
    }

    // MARK: - No entitlement → the trial clock decides

    @Test func noEntitlementWithRunningTrialReportsTrial() {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 3)
        #expect(mgr.status == .trialActive(daysRemaining: 11))
        #expect(!mgr.status.blocksUsage)
    }

    @Test func noEntitlementWithExpiredTrialGates() {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)
        #expect(mgr.status.blocksUsage)
    }

    @Test func noEntitlementAndNoTrialRecordedGates() {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: nil)
        #expect(mgr.status == .trialExpired)
    }

    // MARK: - A blocked entitlement never cuts a running trial short

    @Test func limitReachedDuringTrialPrefersTheTrial() {
        let devices = [ActivatedDevice(name: "Mac A", activatedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        let fake = FakeUnlockProvider(state: .limitReached(devices: devices))
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 3)
        #expect(mgr.status == .trialActive(daysRemaining: 11))
        #expect(!mgr.status.blocksUsage)
    }

    @Test func limitReachedAfterTrialGatesAndCarriesDevices() {
        let devices = [ActivatedDevice(name: "Mac A", activatedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        let fake = FakeUnlockProvider(state: .limitReached(devices: devices))
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .activationLimitReached(devices: devices))
        #expect(mgr.status.blocksUsage)
    }

    @Test func revokedDuringTrialPrefersTheTrial() {
        let fake = FakeUnlockProvider(state: .revoked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 3)
        #expect(mgr.status == .trialActive(daysRemaining: 11))
    }

    @Test func revokedAfterTrialGates() {
        let fake = FakeUnlockProvider(state: .revoked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .licenseRevoked)
        #expect(mgr.status.blocksUsage)
    }

    // MARK: - The provider drives published status

    /// A channel that learns something new (server verdict, StoreKit update)
    /// must be able to push it without the owner polling.
    @Test func providerChangeRecomputesPublishedStatus() {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)

        fake.emit(.unlocked)
        #expect(mgr.status == .activated)

        fake.emit(.revoked)
        #expect(mgr.status == .licenseRevoked)
    }

    @Test func refreshRecomputesFromTheProvider() {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)

        // Change state WITHOUT notifying — refresh() must still pick it up.
        fake.state = .unlocked
        mgr.refresh()
        #expect(mgr.status == .activated)
    }

    // MARK: - Forwarding

    @Test func managerForwardsLicensedEmail() {
        let fake = FakeUnlockProvider(state: .unlocked)
        fake.licensedEmail = "buyer@example.com"
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.licensedEmail == "buyer@example.com")
    }

    @Test func managerForwardsRevalidateWithForceFlag() async {
        let fake = FakeUnlockProvider(state: .unlocked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)

        await mgr.revalidateIfNeeded()
        #expect(fake.revalidateCount == 1)
        #expect(fake.lastRevalidateForced == false)

        await mgr.revalidateIfNeeded(force: true)
        #expect(fake.revalidateCount == 2)
        #expect(fake.lastRevalidateForced == true)
    }

    @Test func managerForwardsDeactivateAndRecomputes() {
        let fake = FakeUnlockProvider(state: .unlocked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .activated)

        mgr.deactivate()
        #expect(fake.deactivateLocallyCount == 1)
        // Entitlement cleared → falls back to the (expired) trial.
        #expect(mgr.status == .trialExpired)
    }

    @Test func managerForwardsDeactivateThisDevice() async {
        let fake = FakeUnlockProvider(state: .unlocked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)

        let freed = await mgr.deactivateThisDevice()
        #expect(freed)
        #expect(fake.deactivateThisDeviceCount == 1)
    }

    @Test func managerForwardsActivate() async {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)

        _ = try? await mgr.activate(keyString: "DROBU-whatever")
        #expect(fake.activateCount == 1)
    }

    // MARK: - The gate does not depend on a conformer remembering to notify
    //
    // `UnlockProviding` cannot enforce `onChange`, and the whole point of the
    // protocol is that a second conformer will exist. A conformer that persists
    // an entitlement but misses one `onChange` on one branch would leave `status`
    // stale until the hourly refresh — "correct on disk, still gated in the UI",
    // a shape this codebase has shipped before. `LicenseManager` therefore
    // recomputes after every forward. Without these three tests, deleting all
    // four of those defensive recomputes would not fail anything, because the
    // fake otherwise always notifies.

    @Test func activateRecomputesEvenWhenTheProviderNeverNotifies() async {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)

        fake.silentStateOnActivate = .unlocked
        _ = try? await mgr.activate(keyString: "DROBU-whatever")

        #expect(mgr.status == .activated)
    }

    @Test func revalidateRecomputesEvenWhenTheProviderNeverNotifies() async {
        let fake = FakeUnlockProvider(state: .unlicensed)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)

        fake.silentStateOnRevalidate = .unlocked
        await mgr.revalidateIfNeeded()

        #expect(mgr.status == .activated)
    }

    @Test func deactivateThisDeviceRecomputesEvenWhenTheProviderNeverNotifies() async {
        let fake = FakeUnlockProvider(state: .unlocked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .activated)

        fake.silentStateOnDeactivateDevice = .unlicensed
        _ = await mgr.deactivateThisDevice()

        #expect(mgr.status == .trialExpired)
    }

    // MARK: - Derived state that changes without the status changing

    /// Regression: `recomputeStatus` publishes only on an actual status change,
    /// so a surface derived from provider state but NOT from `status` would go
    /// stale. Real trace: activate while offline (key stored, no email, status
    /// `.activated`), then a later re-validation returns the email — status is
    /// `.activated` both times, so nothing about `status` changes, yet the
    /// Settings "Licensed to {email}" row must still appear.
    @Test func licensedEmailUpdatesWhenStatusDoesNotChange() {
        let fake = FakeUnlockProvider(state: .unlocked)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .activated)
        #expect(mgr.licensedEmail == nil)

        // Same status, new derived value — the exact case the equality guard
        // would otherwise swallow.
        fake.licensedEmail = "buyer@example.com"
        fake.emit(.unlocked)

        #expect(mgr.status == .activated)
        #expect(mgr.licensedEmail == "buyer@example.com")
    }
}

/// The direct channel's own entitlement mapping, tested at the seam rather than
/// only through `LicenseManager`. `LicenseManagerTests` covers these paths
/// end-to-end; these pin the mapping itself so a future edit to `currentState()`
/// fails here, naming the actual culprit.
@Suite("DirectUnlockProvider entitlement mapping")
@MainActor
struct DirectUnlockProviderTests {

    /// Reports every read as `.denied` — the transient Keychain auth/ACL failure.
    private final class DenyingStore: LicenseStore {
        func get(_ key: String) -> String? { nil }
        func set(_ key: String, _ value: String) {}
        func delete(_ key: String) {}
        func read(_ key: String) -> LicenseStoreRead { .denied }
    }

    private func makeProvider(store: LicenseStore) -> DirectUnlockProvider {
        // A throwaway key: these cases never reach signature verification with a
        // genuine key, and the ones that do assert the failure path.
        let key = Curve25519.Signing.PrivateKey().publicKey
        return DirectUnlockProvider(publicKey: key, store: store)
    }

    @Test func noStoredLicenseIsNone() {
        let provider = makeProvider(store: InMemoryLicenseStore())
        #expect(provider.currentState() == UnlockState.unlicensed)
    }

    /// FAIL OPEN. A denied read must map to `.indeterminate`, never `.none` —
    /// collapsing it to `.none` gates a paying customer, which is the v1.10.1
    /// bug. See `.claude/rules/keychain-and-crypto.md`.
    @Test func deniedReadIsIndeterminateNotNone() {
        let provider = makeProvider(store: DenyingStore())
        #expect(provider.currentState() == .indeterminate)
    }

    /// The inverse hazard: a stored key that fails signature verification must
    /// map to `.none` (fall back to the trial), never `.indeterminate` — that
    /// inversion would fail OPEN and unlock the app on a corrupt or forged key.
    @Test func storedKeyFailingVerificationIsNoneNotIndeterminate() {
        let store = InMemoryLicenseStore()
        store.set("active-license", "DROBU-bm90LXJlYWw.bm90LWEtc2lnbmF0dXJl")
        let provider = makeProvider(store: store)
        #expect(provider.currentState() == UnlockState.unlicensed)
    }
}
