import Foundation
import Testing
@testable import DrobuCore

@Suite struct DeviceIdentityTests {
    @Test func hashIsDeterministicHexAndHidesRawUUID() {
        let uuid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        let h1 = drobuDeviceHash(fromPlatformUUID: uuid, salt: "drobu.device.v1")
        let h2 = drobuDeviceHash(fromPlatformUUID: uuid, salt: "drobu.device.v1")
        #expect(h1 == h2)
        #expect(h1.count == 64) // SHA256 → 32 bytes → 64 hex chars
        #expect(h1.allSatisfy { $0.isHexDigit })
        // The raw UUID must never be recoverable from the hash.
        #expect(!h1.uppercased().contains("ABCDEF01"))
        #expect(!h1.uppercased().contains(uuid))
    }

    @Test func differentUUIDsProduceDifferentHashes() {
        let a = drobuDeviceHash(fromPlatformUUID: "machine-a", salt: "s")
        let b = drobuDeviceHash(fromPlatformUUID: "machine-b", salt: "s")
        #expect(a != b)
    }

    @Test func differentSaltsProduceDifferentHashes() {
        let a = drobuDeviceHash(fromPlatformUUID: "machine", salt: "s1")
        let b = drobuDeviceHash(fromPlatformUUID: "machine", salt: "s2")
        #expect(a != b)
    }

    @Test func usesPlatformUUIDWhenAvailableAndWritesNoFallback() {
        let store = InMemoryLicenseStore()
        let uuid = resolveDeviceUUID(readPlatformUUID: { "HW-UUID-123" }, store: store)
        #expect(uuid == "HW-UUID-123")
        #expect(store.get("device-uuid-fallback") == nil)
    }

    @Test func fallbackPersistsAndIsStableAcrossCalls() {
        let store = InMemoryLicenseStore()
        let first = resolveDeviceUUID(readPlatformUUID: { nil }, store: store)
        let second = resolveDeviceUUID(readPlatformUUID: { nil }, store: store)
        #expect(!first.isEmpty)
        #expect(first == second) // same persisted value, not a fresh random
        #expect(store.get("device-uuid-fallback") == first)
    }

    @Test func emptyPlatformUUIDIsTreatedAsMissingAndFallsBack() {
        let store = InMemoryLicenseStore()
        let uuid = resolveDeviceUUID(readPlatformUUID: { "" }, store: store)
        #expect(!uuid.isEmpty)
        #expect(store.get("device-uuid-fallback") == uuid)
    }

    // MARK: - Non-personal device label

    @Test func labelCombinesModelWithSixHexHashSuffix() {
        let label = drobuDeviceLabel(model: "MacBookPro18,3", deviceHash: "a3f9c1d2deadbeef")
        #expect(label == "MacBookPro18,3 · a3f9c1") // model preserved, 6-hex suffix
    }

    @Test func blankModelFallsBackToMacWithoutLeadingSeparator() {
        #expect(drobuDeviceLabel(model: "", deviceHash: "a3f9c1d2") == "Mac · a3f9c1")
        #expect(drobuDeviceLabel(model: "   ", deviceHash: "a3f9c1d2") == "Mac · a3f9c1")
    }

    @Test func sameModelDifferentHashesProduceDistinctLabels() {
        // The over-cap remediation list must keep two same-model Macs apart.
        let a = drobuDeviceLabel(model: "Macmini9,1", deviceHash: "aaaaaa11")
        let b = drobuDeviceLabel(model: "Macmini9,1", deviceHash: "bbbbbb22")
        #expect(a != b)
    }

    @Test func labelDerivesOnlyFromModelAndHashAndStaysShort() {
        // Structural guarantee: the label is a pure function of (model, hash) —
        // it can carry no personal computer name because it never receives one.
        let label = drobuDeviceLabel(model: "MacBookAir10,1", deviceHash: "0123456789abcdef")
        #expect(label == "MacBookAir10,1 · 012345")
        #expect(label.count < 60) // never approaches the backend's 200-char cap
    }

    @Test func shortHashIsUsedWholeWhenUnderSixChars() {
        #expect(drobuDeviceLabel(model: "Mac15,3", deviceHash: "abc") == "Mac15,3 · abc")
    }
}
