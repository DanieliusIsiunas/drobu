import Foundation

/// First-run gate for the onboarding window, tracked by a `UserDefaults` flag
/// independent of the licensing `trial-start` Keychain key (which is
/// load-bearing for the trial clock and must not be overloaded). Injectable
/// suite → trivially testable.
struct OnboardingGate {
    private let defaults: UserDefaults
    private let key = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True until onboarding has been completed (or skipped) once — drives the
    /// automatic show on first launch. The Settings and menu-bar re-entry points
    /// open onboarding directly and bypass this gate.
    var shouldAutoShow: Bool {
        !defaults.bool(forKey: key)
    }

    /// Mark onboarding done so it never auto-shows again.
    func markCompleted() {
        defaults.set(true, forKey: key)
    }
}
