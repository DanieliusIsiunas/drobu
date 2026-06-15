import CryptoKit
import Foundation
import IOKit

/// Stable, privacy-respecting identity for THIS Mac, used to enforce the
/// per-license device-activation cap. Behind a protocol so the IOKit syscall
/// and the host name stay out of unit-test scope — tests inject a fixed hash.
public protocol DeviceIdentifying: Sendable {
    /// `SHA256(IOPlatformUUID + salt)` as lowercase hex. Never the raw UUID:
    /// only this hash + the device name ever leave the Mac.
    var deviceHash: String { get }
    /// Human-readable ("Daniel's MacBook") for the in-app activated-device list.
    var deviceName: String { get }
}

/// Pure hash — unit-tested without IOKit. The salt namespaces the digest to
/// Drobu so the same Mac's fingerprint can't be correlated across apps. It is
/// not a secret: the hash is not a capability (the signed license key is), it
/// only enforces the cap and de-correlates the identity.
public func drobuDeviceHash(fromPlatformUUID uuid: String, salt: String) -> String {
    let digest = SHA256.hash(data: Data((uuid + salt).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Resolve the device's stable UUID: the hardware `IOPlatformUUID` when
/// available, else a random UUID persisted via `store` so a fingerprint always
/// exists even if the IOKit read is ever unavailable. Pure over its inputs
/// (the reader + the store) — unit-tested with a stubbed reader.
public func resolveDeviceUUID(
    readPlatformUUID: () -> String?,
    store: LicenseStore
) -> String {
    if let uuid = readPlatformUUID(), !uuid.isEmpty { return uuid }
    let key = "device-uuid-fallback"
    if let existing = store.get(key) { return existing }
    let generated = UUID().uuidString
    store.set(key, generated)
    return generated
}

/// Production identity. Reads the hardware UUID via IOKit (mirrors
/// `ClosedLidService`'s IOPMrootDomain read); Developer-ID (non-sandboxed)
/// builds can read `IOPlatformExpertDevice` freely. Empty struct → `Sendable`.
public struct SystemDeviceIdentity: DeviceIdentifying {
    // Bump the suffix only if every device must re-activate (it would reset the
    // whole fleet's fingerprints) — there is no reason to in normal operation.
    private static let salt = "drobu.device.v1"

    public init() {}

    public var deviceHash: String {
        let uuid = resolveDeviceUUID(
            readPlatformUUID: Self.readPlatformUUID,
            store: KeychainLicenseStore()
        )
        return drobuDeviceHash(fromPlatformUUID: uuid, salt: Self.salt)
    }

    public var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// The hardware UUID, or nil if the registry entry/property is missing.
    private static func readPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        return property as? String
    }
}
