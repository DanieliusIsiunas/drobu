import CryptoKit
import Foundation
import IOKit

/// Stable, privacy-respecting identity for THIS Mac, used to enforce the
/// per-license device-activation cap. Behind a protocol so the IOKit syscall
/// and the host name stay out of unit-test scope — tests inject a fixed hash.
public protocol DeviceIdentifying: Sendable {
    /// `SHA256(IOPlatformUUID + salt)` as lowercase hex. Never the raw UUID:
    /// only this hash + the device label ever leave the Mac.
    var deviceHash: String { get }
    /// Non-personal device label (hardware model + a short hash suffix) for the
    /// in-app activated-device list. Never the user's computer name, which macOS
    /// seeds from their real name.
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

/// Non-personal, device-distinguishing label for the activated-device list.
/// Combines the hardware model identifier (e.g. "MacBookPro18,3") with a short
/// prefix of the device hash, so two same-model Macs stay distinguishable in the
/// over-cap remediation screen WITHOUT transmitting the user's computer name
/// (macOS seeds `Host.current().localizedName` from their real name). Pure over
/// its inputs — unit-tested without the `hw.model` syscall.
public func drobuDeviceLabel(model: String, deviceHash: String) -> String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelPart = trimmed.isEmpty ? "Mac" : trimmed
    let suffix = deviceHash.prefix(6)
    return suffix.isEmpty ? modelPart : "\(modelPart) · \(suffix)"
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
        // Resolve the hash once: it drives an IOKit + Keychain read, and callers
        // (LicenseManager) read deviceHash and deviceName back to back.
        let hash = deviceHash
        return drobuDeviceLabel(model: Self.readModelIdentifier() ?? "Mac", deviceHash: hash)
    }

    /// The hardware model identifier (e.g. "MacBookPro18,3"), or nil if the
    /// sysctl read fails. Non-personal — kept out of the pure label function so
    /// `drobuDeviceLabel` stays unit-testable without the syscall (mirrors
    /// `readPlatformUUID`).
    private static func readModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        // hw.model is a NUL-terminated C string. Decode the bytes up to the
        // terminator as UTF-8 (String(cString:) is deprecated). CChar is Int8,
        // so reinterpret each byte's bit pattern as UInt8 for the decoder.
        let model = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return model.isEmpty ? nil : model
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
