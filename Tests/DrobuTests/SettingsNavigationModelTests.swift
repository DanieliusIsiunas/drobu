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

    @Test("selectNext advances one section at a time")
    func selectNextAdvances() {
        let model = SettingsNavigationModel(firstRun: true)   // setUp
        model.selectNext()
        #expect(model.selected == .shortcuts)
        model.selectNext()
        #expect(model.selected == .history)
    }

    @Test("selectNext clamps at the last section (no wrap)")
    func selectNextClamps() {
        let model = SettingsNavigationModel(firstRun: false)
        model.selected = .about
        model.selectNext()
        #expect(model.selected == .about)
    }

    @Test("selectPrevious steps back one section")
    func selectPreviousSteps() {
        let model = SettingsNavigationModel(firstRun: false)  // shortcuts
        model.selectPrevious()
        #expect(model.selected == .setUp)
    }

    @Test("selectPrevious clamps at the first section (no wrap)")
    func selectPreviousClamps() {
        let model = SettingsNavigationModel(firstRun: true)   // setUp
        model.selectPrevious()
        #expect(model.selected == .setUp)
    }

    @Test("select(number:) jumps to the 1-based section")
    func selectByNumber() {
        let model = SettingsNavigationModel(firstRun: true)
        model.select(number: 1)
        #expect(model.selected == .setUp)
        model.select(number: 3)
        #expect(model.selected == .history)
        model.select(number: 5)
        #expect(model.selected == .about)
    }

    @Test("select(number:) ignores out-of-range numbers")
    func selectByNumberOutOfRange() {
        let model = SettingsNavigationModel(firstRun: false)  // shortcuts
        model.select(number: 0)
        #expect(model.selected == .shortcuts)
        model.select(number: 6)
        #expect(model.selected == .shortcuts)
    }
}
