import Testing
import CryptoKit
import Foundation
@testable import DrobuCore

@MainActor
@Suite("LicenseManager")
struct LicenseManagerTests {

    // Generate a fresh keypair per test process. Tests never touch
    // the real Info.plist key or the real Keychain.
    private let testPrivateKey = Curve25519.Signing.PrivateKey()
    private var testPublicKey: Curve25519.Signing.PublicKey { testPrivateKey.publicKey }

    /// Build a valid license key from a payload, signing with the
    /// test private key. Mirrors what `issue-license-key.sh` produces.
    private func makeKey(payload: Data, signingWith privateKey: Curve25519.Signing.PrivateKey? = nil) -> String {
        let key = privateKey ?? testPrivateKey
        let sig = try! key.signature(for: payload)
        return "DROBU-\(b64url(payload)).\(b64url(sig))"
    }

    private func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomPayload() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }

    /// Store double simulating the real Keychain's silent write-failure
    /// mode: `set` is a no-op for the configured keys (matching
    /// KeychainLicenseStore, which surfaces failures only via Log).
    private final class WriteFailingLicenseStore: LicenseStore {
        private var storage: [String: String] = [:]
        private let failingKeys: Set<String>
        init(failingKeys: Set<String>) { self.failingKeys = failingKeys }
        func get(_ key: String) -> String? { storage[key] }
        func set(_ key: String, _ value: String) {
            guard !failingKeys.contains(key) else { return }
            storage[key] = value
        }
        func delete(_ key: String) { storage.removeValue(forKey: key) }
    }

    // MARK: - Trial state

    @Test func freshLaunchStartsTrialAtFullDuration() {
        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        mgr.recordFirstLaunchIfNeeded()
        #expect(mgr.status == .trialActive(daysRemaining: 14))
    }

    @Test func recordFirstLaunchIsIdempotent() {
        // Calling recordFirstLaunchIfNeeded multiple times must not extend
        // the trial — the timestamp is locked in on first call.
        let store = InMemoryLicenseStore()
        let originalStart = Date()
        var currentTime = originalStart
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        // Advance time by 5 days, call again
        currentTime = originalStart.addingTimeInterval(5 * 86400)
        mgr.recordFirstLaunchIfNeeded()
        mgr.refresh()
        // Should show ~9 days remaining (14 - 5), NOT 14
        #expect(mgr.status == .trialActive(daysRemaining: 9))
    }

    @Test func trialDay13ShowsOneDayRemaining() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)  // fixed whole second: lossless ISO round-trip → deterministic boundary
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(13 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 1))
    }

    @Test func trialAtExpiryBoundaryIsExpired() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)  // fixed whole second: lossless ISO round-trip → deterministic boundary
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(14 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)
    }

    @Test func trialPastBoundaryIsExpired() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)  // fixed whole second: lossless ISO round-trip → deterministic boundary
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(15 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)
    }

    @Test func unrecordedFirstLaunchStaysExpired() {
        // If recordFirstLaunchIfNeeded has never been called, the gate
        // is closed. This is the fail-closed default that ensures a
        // bug in app startup never accidentally grants free use.
        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(mgr.status == .trialExpired)
    }

    @Test func failedTrialStartWriteStaysFailClosed() {
        // If the Keychain silently swallows the trial-start write, the
        // read-back sees nil and the gate stays closed — the degraded
        // mode is fail-closed (and logged), never a free pass.
        let store = WriteFailingLicenseStore(failingKeys: ["trial-start"])
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        mgr.recordFirstLaunchIfNeeded()
        #expect(mgr.status == .trialExpired)
    }

    @Test func storedButInvalidLicenseFallsBackToTrialState() {
        // An active-license entry that reads but fails verification must
        // not activate — status falls through to the underlying trial.
        let store = InMemoryLicenseStore()
        store.set("active-license", "DROBU-bm90LXJlYWw.bm90LWEtc2lnbmF0dXJl")
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        mgr.recordFirstLaunchIfNeeded()
        #expect(mgr.status == .trialActive(daysRemaining: 14))
    }

    // MARK: - Clock-rollback anchor

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    @Test func rollbackDoesNotRegainDays() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(5 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 9))

        // Roll the clock back 10 days — status must stay clamped to day 5.
        currentTime = start.addingTimeInterval(-5 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 9))
    }

    @Test func rollbackPastExpiryStaysExpired() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(15 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)

        // Rolling back into the trial window must not reopen the gate.
        currentTime = start.addingTimeInterval(5 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)
    }

    @Test func forwardExcursionThenCorrectionBurnsTrial() {
        // The accepted trade-off: a forward clock excursion advances the
        // anchor permanently; correcting the clock does not restore days.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(20 * 86400)
        mgr.refresh()
        currentTime = start.addingTimeInterval(1 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)
    }

    @Test func migrationWithoutAnchorBehavesAsTodayAndCreatesAnchor() {
        // Existing installs have trial-start but no last-seen: the first
        // recompute must not change their status, and must create the anchor.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.set("trial-start", iso(start))
        let nowDate = start.addingTimeInterval(5 * 86400)
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { nowDate })
        #expect(mgr.status == .trialActive(daysRemaining: 9))
        #expect(store.get("last-seen") == iso(nowDate))
    }

    @Test func futureTrialStartGatesThenSelfHeals() {
        // A future-dated trial-start is a delayed trial, not a permanent
        // brick: gated (fail-closed) until the clock passes it, then the
        // full window opens. The anchor is persisted even while gated.
        let store = InMemoryLicenseStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.set("trial-start", iso(base.addingTimeInterval(10 * 86400)))
        var currentTime = base
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        #expect(mgr.status == .trialExpired)
        #expect(store.get("last-seen") == iso(base))

        currentTime = base.addingTimeInterval(11 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 13))
    }

    @Test func corruptAnchorSelfHeals() {
        // Unparseable last-seen is treated as missing (status computed
        // from the raw clock) and overwritten with a valid value.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.set("trial-start", iso(start))
        store.set("last-seen", "garbage")
        let nowDate = start.addingTimeInterval(2 * 86400)
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { nowDate })
        #expect(mgr.status == .trialActive(daysRemaining: 12))
        #expect(store.get("last-seen") == iso(nowDate))
    }

    @Test func corruptTrialStartStaysClosedAndIsNotOverwritten() {
        let store = InMemoryLicenseStore()
        store.set("trial-start", "garbage")
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(mgr.status == .trialExpired)
        mgr.recordFirstLaunchIfNeeded()
        mgr.refresh()
        #expect(mgr.status == .trialExpired)
        #expect(store.get("trial-start") == "garbage")
    }

    @Test func staleAnchorWriteFailureDegradesToPreAnchorBehavior() {
        // If the Keychain silently swallows last-seen writes, the clamp
        // degrades to today's behavior (rollback works) without crashing —
        // the U3 logging makes the degraded mode observable in production.
        let store = WriteFailingLicenseStore(failingKeys: ["last-seen"])
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(5 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 9))

        currentTime = start.addingTimeInterval(3 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 11))
    }

    @Test func activatedNeverTouchesAnchor() throws {
        // While a valid license is active, recomputes neither read nor
        // write last-seen — no Keychain churn for paying customers.
        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        try mgr.activate(keyString: makeKey(payload: randomPayload()))
        mgr.refresh()
        mgr.refresh()
        #expect(mgr.status == .activated)
        #expect(store.get("last-seen") == nil)
    }

    @Test func anchorPersistsAcrossManagerInstances() {
        // A fresh manager against the same store inherits the anchor —
        // restarting the app with a rolled-back clock stays clamped.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var time1 = start
        let mgr1 = LicenseManager(publicKey: testPublicKey, store: store, now: { time1 })
        mgr1.recordFirstLaunchIfNeeded()
        time1 = start.addingTimeInterval(5 * 86400)
        mgr1.refresh()

        let rolledBack = start.addingTimeInterval(1 * 86400)
        let mgr2 = LicenseManager(publicKey: testPublicKey, store: store, now: { rolledBack })
        #expect(mgr2.status == .trialActive(daysRemaining: 9))
    }

    @Test func anchorWinsAfterDeactivateWhenClockRolledBelowIt() throws {
        // Complement of the accepted-residual deactivate test: when the
        // pre-activation anchor is AHEAD of the rolled-back clock, the
        // clamp engages — deactivate computes from the anchor, not raw now.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(10 * 86400)
        mgr.refresh()  // anchor advances to day 10
        try mgr.activate(keyString: makeKey(payload: randomPayload()))

        currentTime = start.addingTimeInterval(5 * 86400)  // roll below the anchor
        mgr.deactivate()
        #expect(mgr.status == .trialActive(daysRemaining: 4))
    }

    @Test func anchorFreezesAtPreActivationValueWhileActivated() throws {
        // A non-nil anchor created by the trial path must stop advancing
        // once activated — activatedNeverTouchesAnchor only covers the
        // starts-nil-stays-nil case, which a buggy always-write would pass.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(3 * 86400)
        mgr.refresh()
        let frozen = store.get("last-seen")
        #expect(frozen == iso(currentTime))

        try mgr.activate(keyString: makeKey(payload: randomPayload()))
        currentTime = start.addingTimeInterval(9 * 86400)
        mgr.refresh()
        mgr.refresh()
        #expect(mgr.status == .activated)
        #expect(store.get("last-seen") == frozen)
    }

    // MARK: - Accepted tamper residuals (acceptance tests)
    //
    // These pin the *chosen* limits of the anchor (it closes clock
    // rollback without Keychain tampering, nothing more) so any future
    // change to these behaviors is deliberate, not accidental.

    @Test func acceptedResidual_anchorWipeReopensTrial() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(15 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)

        store.delete("last-seen")
        currentTime = start.addingTimeInterval(5 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialActive(daysRemaining: 9))
    }

    @Test func acceptedResidual_trialStartWipeGrantsFreshTrial() {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(5 * 86400)
        mgr.refresh()

        store.delete("trial-start")
        mgr.recordFirstLaunchIfNeeded()  // logs tamper evidence, proceeds
        #expect(mgr.status == .trialActive(daysRemaining: 14))
    }

    @Test func acceptedResidual_deactivateAfterRollbackUsesFrozenAnchor() throws {
        // The anchor is frozen while activated, so deactivating after a
        // rollback computes from max(now, pre-activation anchor). Only
        // someone who already owns a valid license can reach this state.
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()
        currentTime = start.addingTimeInterval(2 * 86400)
        try mgr.activate(keyString: makeKey(payload: randomPayload()))
        currentTime = start.addingTimeInterval(20 * 86400)
        mgr.refresh()
        #expect(mgr.status == .activated)

        currentTime = start.addingTimeInterval(6 * 86400)
        mgr.deactivate()
        #expect(mgr.status == .trialActive(daysRemaining: 8))
    }

    // MARK: - Activation

    @Test func validKeyActivates() throws {
        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        let key = makeKey(payload: randomPayload())
        try mgr.activate(keyString: key)
        #expect(mgr.status == .activated)
    }

    @Test func activationPersistsAcrossManagerInstances() throws {
        // A new LicenseManager built against the same store recovers
        // the activated state on startup — proves the persistence path.
        let store = InMemoryLicenseStore()
        let mgr1 = LicenseManager(publicKey: testPublicKey, store: store)
        try mgr1.activate(keyString: makeKey(payload: randomPayload()))
        #expect(mgr1.status == .activated)

        let mgr2 = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(mgr2.status == .activated)
    }

    @Test func activatedTakesPrecedenceOverExpiredTrial() throws {
        let store = InMemoryLicenseStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)  // fixed whole second: lossless ISO round-trip → deterministic boundary
        var currentTime = start
        let mgr = LicenseManager(publicKey: testPublicKey, store: store, now: { currentTime })
        mgr.recordFirstLaunchIfNeeded()

        // Fast-forward past trial expiry.
        currentTime = start.addingTimeInterval(20 * 86400)
        mgr.refresh()
        #expect(mgr.status == .trialExpired)

        // Activate after expiry — should flip status to activated.
        try mgr.activate(keyString: makeKey(payload: randomPayload()))
        #expect(mgr.status == .activated)
    }

    @Test func deactivateRevealsTrialState() throws {
        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        mgr.recordFirstLaunchIfNeeded()
        try mgr.activate(keyString: makeKey(payload: randomPayload()))
        #expect(mgr.status == .activated)
        mgr.deactivate()
        #expect(mgr.status == .trialActive(daysRemaining: 14))
    }

    // MARK: - Malformed keys

    @Test(
        "Malformed keys throw .malformed",
        arguments: [
            "",
            "not-a-real-key",
            "DROBU-",
            "DROBU-abcdef",                      // missing dot separator
            "DROBU-.signature",                  // empty payload
            "DROBU-payload.",                    // empty signature
            "DROBU-!!!.???",                     // non-base64url
            "lowercase-prefix.abc",              // wrong prefix
        ]
    )
    func malformedKeysAreRejected(_ keyString: String) {
        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(throws: LicenseError.malformed) {
            try mgr.activate(keyString: keyString)
        }
        // Status must not change on failed activation.
        #expect(mgr.status == .trialExpired)
    }

    // MARK: - Bad signatures

    @Test func signatureFromDifferentKeypairFails() {
        // Sign with a foreign private key; verify against ours.
        // Structurally valid, signature lies — should be `.badSignature`.
        let otherKey = Curve25519.Signing.PrivateKey()
        let key = makeKey(payload: randomPayload(), signingWith: otherKey)

        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(throws: LicenseError.badSignature) {
            try mgr.activate(keyString: key)
        }
    }

    @Test func zeroedSignatureFails() {
        // Valid base64 structure but the signature is 64 zero bytes —
        // cannot possibly verify.
        let payload = randomPayload()
        let zeroSig = Data(count: 64)
        let key = "DROBU-\(b64url(payload)).\(b64url(zeroSig))"

        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(throws: LicenseError.badSignature) {
            try mgr.activate(keyString: key)
        }
    }

    @Test func tamperedPayloadFails() throws {
        // Valid signature for one payload, but the payload bytes in the
        // key string have been modified by one byte. Must reject.
        let originalPayload = randomPayload()
        var tamperedPayload = originalPayload
        tamperedPayload[0] = tamperedPayload[0] &+ 1
        let sig = try testPrivateKey.signature(for: originalPayload)
        let key = "DROBU-\(b64url(tamperedPayload)).\(b64url(sig))"

        let store = InMemoryLicenseStore()
        let mgr = LicenseManager(publicKey: testPublicKey, store: store)
        #expect(throws: LicenseError.badSignature) {
            try mgr.activate(keyString: key)
        }
    }

    // MARK: - Base64URL decoding

    @Test func base64URLDecodeHandlesStandardCharacters() {
        let original = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = original.base64EncodedString()
        #expect(LicenseManager.base64URLDecode(encoded) == original)
    }

    @Test func base64URLDecodeHandlesURLSafeAlphabet() {
        // 0x3e 0x3f bytes encode to `+/` in standard base64, `-_` in URL-safe.
        let withSpecial = Data([0x3e, 0x3f])
        let urlSafe = withSpecial.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(LicenseManager.base64URLDecode(urlSafe) == withSpecial)
    }

    @Test func base64URLDecodeRejectsGarbage() {
        #expect(LicenseManager.base64URLDecode("!!!") == nil)
    }
}
