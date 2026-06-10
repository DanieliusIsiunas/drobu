import Foundation
import Testing
@testable import DrobuShared

/// B1: the daemon validates its code-sign requirement string at startup and
/// fails closed (exits) if it cannot parse — a silently-unapplied requirement
/// is identical to no gate against a root daemon. This covers the parse gate;
/// the live per-connection enforcement + negative-path rejection are U7.
@Suite("RequirementValidation (B1 fail-closed gate)")
struct RequirementValidationTests {

    @Test("the pinned client requirement parses")
    func pinnedRequirementParses() {
        #expect(isParseableCodeSigningRequirement(DaemonConstants.clientCodeSigningRequirement))
    }

    @Test("a well-formed Team-ID requirement parses")
    func wellFormedParses() {
        #expect(isParseableCodeSigningRequirement(#"anchor apple generic and certificate leaf[subject.OU] = "TGL69S88MD""#))
    }

    @Test("garbage requirement strings do not parse (→ daemon must fail closed)")
    func garbageRejected() {
        #expect(isParseableCodeSigningRequirement("this is not a requirement (((") == false)
        #expect(isParseableCodeSigningRequirement("") == false)
        #expect(isParseableCodeSigningRequirement("anchor apple generic and identifier") == false) // dangling
    }
}
