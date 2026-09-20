import Testing
import Foundation
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

    init(state: UnlockState = .none) {
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
        return nil
    }

    func deactivateThisDevice() async -> Bool {
        deactivateThisDeviceCount += 1
        return true
    }

    func deactivateLocally() {
        deactivateLocallyCount += 1
        state = .none
        onChange?()
    }

    func revalidateIfNeeded(force: Bool) async {
        revalidateCount += 1
        lastRevalidateForced = force
    }
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
        let fake = FakeUnlockProvider(state: .none)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 3)
        #expect(mgr.status == .trialActive(daysRemaining: 11))
        #expect(!mgr.status.blocksUsage)
    }

    @Test func noEntitlementWithExpiredTrialGates() {
        let fake = FakeUnlockProvider(state: .none)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)
        #expect(mgr.status.blocksUsage)
    }

    @Test func noEntitlementAndNoTrialRecordedGates() {
        let fake = FakeUnlockProvider(state: .none)
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
        let fake = FakeUnlockProvider(state: .none)
        let mgr = makeManager(unlock: fake, trialStartedDaysAgo: 99)
        #expect(mgr.status == .trialExpired)

        fake.emit(.unlocked)
        #expect(mgr.status == .activated)

        fake.emit(.revoked)
        #expect(mgr.status == .licenseRevoked)
    }

    @Test func refreshRecomputesFromTheProvider() {
        let fake = FakeUnlockProvider(state: .none)
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
}
