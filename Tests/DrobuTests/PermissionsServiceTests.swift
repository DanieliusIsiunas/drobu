import Foundation
import Testing
@testable import DrobuCore

/// Mock probe whose per-permission grant state can change between the
/// PermissionsService init (launch baseline) and a later `state(for:)` read,
/// so the restart-pending rule is exercised deterministically.
@MainActor
final class MockPermissionProbe: PermissionProbing {
    var grants: [Permission: Bool?]
    init(_ grants: [Permission: Bool?]) { self.grants = grants }
    func isGranted(_ permission: Permission) -> Bool? {
        // Bool?? flattened: missing key → nil (notApplicable).
        grants[permission] ?? nil
    }
}

@MainActor
@Suite("PermissionsService")
struct PermissionsServiceTests {

    @Test("restart-requiring permission granted at launch → .granted (no restart needed)")
    func restartPermGrantedAtLaunch() {
        let probe = MockPermissionProbe([.accessibility: true])
        let service = PermissionsService(probe: probe)
        #expect(service.state(for: .accessibility) == .granted)
    }

    @Test("restart-requiring permission granted only this session → .pendingRestart")
    func restartPermGrantedThisSession() {
        let probe = MockPermissionProbe([.accessibility: false])
        let service = PermissionsService(probe: probe)   // baseline: not granted
        probe.grants[.accessibility] = true              // granted after launch
        #expect(service.state(for: .accessibility) == .pendingRestart)
    }

    @Test("restart-requiring permission not granted now → .notGranted (baseline irrelevant)")
    func restartPermNotGranted() {
        let probe = MockPermissionProbe([.screenRecording: true])
        let service = PermissionsService(probe: probe)   // baseline: granted
        probe.grants[.screenRecording] = false           // revoked after launch
        #expect(service.state(for: .screenRecording) == .notGranted)
    }

    @Test("non-restart permission granted now → .granted, never .pendingRestart")
    func nonRestartPermGrantedThisSession() {
        let probe = MockPermissionProbe([.closedLidHelper: false])
        let service = PermissionsService(probe: probe)   // baseline: not granted
        probe.grants[.closedLidHelper] = true            // granted after launch
        #expect(service.state(for: .closedLidHelper) == .granted)   // no restart concept
    }

    @Test("non-restart permission not granted → .notGranted")
    func nonRestartPermNotGranted() {
        let probe = MockPermissionProbe([.launchAtLogin: false])
        #expect(PermissionsService(probe: probe).state(for: .launchAtLogin) == .notGranted)
    }

    @Test("permission the probe reports as nil → .notApplicable")
    func notApplicable() {
        let probe = MockPermissionProbe([.pasteboard: Bool?.none])  // present key, nil value
        #expect(PermissionsService(probe: probe).state(for: .pasteboard) == .notApplicable)
    }

    @Test("requiredSatisfied true when all required are granted/pending, ignoring optional")
    func requiredSatisfiedTrue() {
        let probe = MockPermissionProbe([
            .accessibility: false,   // becomes granted-this-session below → pendingRestart
            .pasteboard: true,       // granted (non-restart)
            .screenRecording: false, // optional, not granted — must not affect the result
        ])
        let service = PermissionsService(probe: probe)
        probe.grants[.accessibility] = true
        #expect(service.requiredSatisfied(required: [.accessibility, .pasteboard]))
    }

    @Test("requiredSatisfied false when any required is notGranted")
    func requiredSatisfiedFalse() {
        let probe = MockPermissionProbe([.accessibility: true, .pasteboard: false])
        let service = PermissionsService(probe: probe)
        #expect(!service.requiredSatisfied(required: [.accessibility, .pasteboard]))
    }

    @Test("requiredSatisfied treats a notApplicable required permission as satisfied")
    func requiredSatisfiedNotApplicable() {
        let probe = MockPermissionProbe([.accessibility: true, .pasteboard: Bool?.none])
        let service = PermissionsService(probe: probe)
        #expect(service.requiredSatisfied(required: [.accessibility, .pasteboard]))
    }
}
