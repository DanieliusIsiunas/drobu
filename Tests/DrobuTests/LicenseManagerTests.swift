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
