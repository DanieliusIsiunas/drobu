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

    @Test("completion is .ready only when every required permission works now")
    func completionReady() {
        let probe = MockPermissionProbe([.accessibility: true, .pasteboard: true])
        let service = PermissionsService(probe: probe)   // both granted at launch
        #expect(service.completion(required: [.accessibility, .pasteboard]) == .ready)
    }

    @Test("completion is .pendingRestart when a required permission was granted only this session")
    func completionPendingRestart() {
        let probe = MockPermissionProbe([.accessibility: false, .pasteboard: true])
        let service = PermissionsService(probe: probe)
        probe.grants[.accessibility] = true   // granted after launch → needs restart
        #expect(service.completion(required: [.accessibility, .pasteboard]) == .pendingRestart)
    }

    @Test("completion is .incomplete when any required permission is not granted")
    func completionIncomplete() {
        let probe = MockPermissionProbe([.accessibility: true, .pasteboard: false])
        let service = PermissionsService(probe: probe)
        #expect(service.completion(required: [.accessibility, .pasteboard]) == .incomplete)
    }

    @Test("completion treats a notApplicable required permission as satisfied (.ready)")
    func completionNotApplicableIsReady() {
        let probe = MockPermissionProbe([.accessibility: true, .pasteboard: Bool?.none])
        let service = PermissionsService(probe: probe)
        #expect(service.completion(required: [.accessibility, .pasteboard]) == .ready)
    }

    // MARK: - Screen Recording window-name signal (CGPreflight false-negative fallback)

    @Test("SR window signal: a foreign window with a non-empty title means granted")
    func srWindowSignalForeignTitle() {
        let windows: [(ownerPID: pid_t, name: String?)] = [
            (ownerPID: 1, name: "Safari — Apple"),   // foreign, titled → visible only with permission
            (ownerPID: 42, name: nil),               // our own window
        ]
        #expect(screenRecordingGrantedFromWindows(windows, ourPID: 42))
    }

    @Test("SR window signal: only redacted-foreign or own windows means not granted")
    func srWindowSignalRedacted() {
        let windows: [(ownerPID: pid_t, name: String?)] = [
            (ownerPID: 1, name: ""),       // foreign but redacted (no permission)
            (ownerPID: 7, name: nil),      // foreign, no title
            (ownerPID: 42, name: "Drobu"), // our own titled window — must be ignored
        ]
        #expect(!screenRecordingGrantedFromWindows(windows, ourPID: 42))
    }

    @Test("SR window signal: empty window list → not granted")
    func srWindowSignalEmpty() {
        #expect(!screenRecordingGrantedFromWindows([], ourPID: 42))
    }

    // MARK: - Pasteboard accessBehavior raw-value mapping (macOS 15.4+)

    @Test("pasteboard grant signal: only alwaysAllow (2) is a grant; default/ask/deny are not")
    func pasteboardRawAccessBehaviorMapping() {
        #expect(pasteboardAccessGranted(rawAccessBehavior: 0) == false)  // default — prompt-on-access, NOT a grant
        #expect(pasteboardAccessGranted(rawAccessBehavior: 1) == false)  // ask
        #expect(pasteboardAccessGranted(rawAccessBehavior: 2) == true)   // alwaysAllow — silent reads
        #expect(pasteboardAccessGranted(rawAccessBehavior: 3) == false)  // alwaysDeny
    }
}
