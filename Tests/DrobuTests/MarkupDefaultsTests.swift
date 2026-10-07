import Foundation
import Testing
@testable import DrobuCore

@Suite("MarkupDefaults")
struct MarkupDefaultsTests {

    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.danielius.ClipboardHistory.markup-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func defaultsToRed() {
        withFreshDefaults { defaults in
            #expect(MarkupDefaults.loadColor(from: defaults) == .red)
        }
    }

    @Test func remembersSavedColor() {
        withFreshDefaults { defaults in
            MarkupDefaults.saveColor(.yellow, to: defaults)
            #expect(MarkupDefaults.loadColor(from: defaults) == .yellow)
        }
    }

    @Test func unknownStoredValueFallsBackToRed() {
        withFreshDefaults { defaults in
            defaults.set("magenta", forKey: MarkupDefaults.colorKey)
            #expect(MarkupDefaults.loadColor(from: defaults) == .red)
        }
    }
}
