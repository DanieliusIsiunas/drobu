import Foundation
import Testing
@testable import DrobuCore

@Suite struct ActivationCopyTests {
    @Test func overCapMessageNamesTheCountAndRemediation() {
        let msg = ActivationCopy.overCapMessage(deviceCount: 3)
        #expect(msg.contains("3 Macs"))
        #expect(msg.contains("Deactivate this Mac"))
    }

    @Test func overCapMessageSingularizesOneDevice() {
        let msg = ActivationCopy.overCapMessage(deviceCount: 1)
        #expect(msg.contains("1 Mac"))
        #expect(!msg.contains("1 Macs"))
    }

    @Test func revokedMessagePointsToSupport() {
        #expect(ActivationCopy.revokedMessage.contains(PurchaseLinks.supportEmail))
    }

    @Test func deviceLineShowsNameAndDate() {
        let device = ActivatedDevice(
            name: "Daniel's MacBook",
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let line = ActivationCopy.deviceLine(device)
        #expect(line.contains("Daniel's MacBook"))
        #expect(line.lowercased().contains("activated"))
    }
}
