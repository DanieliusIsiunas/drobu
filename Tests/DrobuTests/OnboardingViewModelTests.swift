import Foundation
import Testing
@testable import DrobuCore

@MainActor
@Suite("OnboardingViewModel")
struct OnboardingViewModelTests {

    private func makeModel(_ grants: [Permission: Bool?]) -> (OnboardingViewModel, MockPermissionProbe) {
        let probe = MockPermissionProbe(grants)
        let model = OnboardingViewModel(permissions: PermissionsService(probe: probe))
        return (model, probe)
    }

    // Every permission granted-at-launch except where noted, on a 15.4+-style
    // probe (pasteboard present).
    private func allApplicable(_ overrides: [Permission: Bool?] = [:]) -> [Permission: Bool?] {
        var g: [Permission: Bool?] = [
            .accessibility: true, .screenRecording: true, .pasteboard: true,
            .closedLidHelper: true, .launchAtLogin: true,
        ]
        for (k, v) in overrides { g[k] = v }
        return g
    }

    @Test("on macOS 15.4+ (pasteboard applicable) the checklist includes the Pasteboard row, required")
    func includesPasteboardWhenApplicable() {
        let (model, _) = makeModel(allApplicable())
        let pasteboard = model.rows.first { $0.permission == .pasteboard }
        #expect(pasteboard != nil)
        #expect(pasteboard?.tier == .required)
    }

    @Test("below macOS 15.4 (pasteboard not applicable) the Pasteboard row is absent")
    func excludesPasteboardWhenNotApplicable() {
        let (model, _) = makeModel(allApplicable([.pasteboard: Bool?.none]))
        #expect(!model.rows.contains { $0.permission == .pasteboard })
    }

    @Test("rows are tiered: Accessibility + Pasteboard required; capture, daemon, login optional")
    func tiering() {
        let (model, _) = makeModel(allApplicable())
        #expect(Set(model.requiredRows.map(\.permission)) == [.accessibility, .pasteboard])
        #expect(Set(model.optionalRows.map(\.permission)) == [.screenRecording, .closedLidHelper, .launchAtLogin])
    }

    @Test("a granted restart-permission row has no action; not-granted opens Settings; pending offers restart")
    func accessibilityActionByState() {
        // granted at launch → no action
        let (granted, _) = makeModel(allApplicable())
        #expect(granted.rows.first { $0.permission == .accessibility }?.primaryAction == nil)

        // not granted → open Accessibility settings
        let (denied, _) = makeModel(allApplicable([.accessibility: false]))
        #expect(denied.rows.first { $0.permission == .accessibility }?.primaryAction == .openAccessibilitySettings)

        // granted this session → restart
        let (pending, probe) = makeModel(allApplicable([.accessibility: false]))
        probe.grants[.accessibility] = true
        pending.refresh()
        #expect(pending.rows.first { $0.permission == .accessibility }?.primaryAction == .restart)
    }

    @Test("closed-lid row maps to enable; launch-at-login maps to a toggle reflecting current state")
    func optionalActionMapping() {
        let (model, _) = makeModel(allApplicable([.closedLidHelper: false, .launchAtLogin: false]))
        #expect(model.rows.first { $0.permission == .closedLidHelper }?.primaryAction == .enableClosedLidHelper)
        #expect(model.rows.first { $0.permission == .launchAtLogin }?.primaryAction == .toggleLaunchAtLogin(enable: true))

        let (on, _) = makeModel(allApplicable())   // launchAtLogin granted
        #expect(on.rows.first { $0.permission == .launchAtLogin }?.primaryAction == .toggleLaunchAtLogin(enable: false))
    }

    @Test("isComplete is driven only by required rows — optional ungranted is still complete")
    func completionIgnoresOptional() {
        let (model, _) = makeModel(allApplicable([
            .screenRecording: false, .closedLidHelper: false, .launchAtLogin: false,   // all optional off
        ]))
        #expect(model.isComplete)
    }

    @Test("isComplete is false while a required permission is not granted, true once it is")
    func completionTracksRequired() {
        let (model, probe) = makeModel(allApplicable([.accessibility: false]))
        #expect(!model.isComplete)
        probe.grants[.accessibility] = true   // granted this session → pendingRestart counts as satisfied
        model.refresh()
        #expect(model.isComplete)
    }

    @Test("refresh() picks up a state change from the probe")
    func refreshUpdatesRows() {
        let (model, probe) = makeModel(allApplicable([.screenRecording: false]))
        #expect(model.rows.first { $0.permission == .screenRecording }?.state == .notGranted)
        probe.grants[.screenRecording] = true   // granted this session
        model.refresh()
        #expect(model.rows.first { $0.permission == .screenRecording }?.state == .pendingRestart)
    }
}
