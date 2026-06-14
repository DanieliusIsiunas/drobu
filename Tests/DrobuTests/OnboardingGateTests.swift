import Foundation
import Testing
@testable import DrobuCore

@Suite("OnboardingGate")
struct OnboardingGateTests {

    /// A throwaway, isolated defaults suite per test (cleaned up after).
    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.danielius.ClipboardHistory.onboarding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("fresh defaults → shouldAutoShow is true")
    func freshAutoShows() {
        withFreshDefaults { defaults in
            #expect(OnboardingGate(defaults: defaults).shouldAutoShow)
        }
    }

    @Test("after markCompleted → shouldAutoShow is false")
    func completedDoesNotAutoShow() {
        withFreshDefaults { defaults in
            OnboardingGate(defaults: defaults).markCompleted()
            #expect(!OnboardingGate(defaults: defaults).shouldAutoShow)
        }
    }

    @Test("completion persists across a new gate instance on the same suite")
    func persistsAcrossInstances() {
        withFreshDefaults { defaults in
            let first = OnboardingGate(defaults: defaults)
            #expect(first.shouldAutoShow)
            first.markCompleted()
            #expect(!OnboardingGate(defaults: defaults).shouldAutoShow)   // a fresh instance sees it
        }
    }
}
