import Foundation
import Security

/// B1: validate that a code-signing requirement string actually parses before
/// the daemon trusts it as the gate for incoming XPC peers.
///
/// A requirement that silently fails to apply is identical to NO requirement —
/// against a root daemon that means every local caller is accepted. So the
/// daemon validates its requirement string at startup and **`exit`s** if this
/// returns false (fail closed), rather than running with an unenforced gate.
/// This is the one piece of the fail-closed control that is unit-testable
/// without the XPC wire; the per-connection enforcement and the negative-path
/// (different-identity) rejection are verified live in U7.
public func isParseableCodeSigningRequirement(_ requirement: String) -> Bool {
    var req: SecRequirement?
    let status = SecRequirementCreateWithString(requirement as CFString, [], &req)
    return status == errSecSuccess && req != nil
}
