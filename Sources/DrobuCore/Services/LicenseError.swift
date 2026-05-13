import Foundation

/// Failures that the license-key activation flow can raise.
///
/// `malformed` covers any structural problem with the pasted key —
/// missing `DROBU-` prefix, missing `.` separator, non-base64url body.
///
/// `badSignature` means the structure parsed but the signature does
/// not verify against the embedded public key (wrong keypair, tampered
/// payload, or random garbage that happened to be valid base64).
///
/// `publicKeyMissing` should only ever appear in development — the
/// embedded `DrobuLicensePublicKey` value in `Info.plist` was absent
/// or unparseable.
public enum LicenseError: Error, Equatable {
    case malformed
    case badSignature
    case publicKeyMissing
}
