import Foundation
import Testing
@testable import DrobuCore

@MainActor
@Suite("SettingsNavigationModel")
struct SettingsNavigationModelTests {

    @Test("landingSection: first run → Set Up, ongoing → Shortcuts")
    func landing() {
        #expect(landingSection(firstRun: true) == .setUp)
        #expect(landingSection(firstRun: false) == .shortcuts)
    }

    @Test("welcome chrome shows ONLY for Set Up on first run")
    func chrome() {
        #expect(showsWelcomeChrome(in: .setUp, firstRun: true))
        #expect(!showsWelcomeChrome(in: .setUp, firstRun: false))   // revisited later → plain
        #expect(!showsWelcomeChrome(in: .shortcuts, firstRun: true)) // chrome is Set-Up-only
        #expect(!showsWelcomeChrome(in: .history, firstRun: true))
        #expect(!showsWelcomeChrome(in: .license, firstRun: false))
    }

    @Test("section order is the fixed blueprint")
    func order() {
        #expect(SettingsSection.allCases == [.setUp, .shortcuts, .history, .license, .about])
    }

    @Test("every section has a non-empty title and symbol")
    func titlesAndSymbols() {
        for section in SettingsSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbolName.isEmpty)
        }
    }

    @Test("model lands on the right section per mode")
    func modelLanding() {
        #expect(SettingsNavigationModel(firstRun: true).selected == .setUp)
        #expect(SettingsNavigationModel(firstRun: false).selected == .shortcuts)
    }

    @Test("model selection is mutable (sidebar clicks change it)")
    func modelSelectionMutates() {
        let model = SettingsNavigationModel(firstRun: false)
        #expect(model.selected == .shortcuts)
        model.selected = .about
        #expect(model.selected == .about)
    }
}
