import Foundation

public extension Notification.Name {
    static let openSettingsFromMenu = Notification.Name("openSettingsFromMenu")
    /// Posted from Settings ("Setup & Permissions") to re-open the onboarding
    /// panel on demand. AppDelegate owns the panel (the Settings scene runs under
    /// .regular policy and can't reach the delegate directly).
    static let openOnboardingRequested = Notification.Name("openOnboardingRequested")
    /// Posted when Closed Lid activation needs the daemon registered/approved.
    /// AppDelegate turns it into an NSAlert with an "Open System Settings"
    /// action (the Settings scene's `.alert` does not fire — see swiftui rules).
    static let daemonNotApproved = Notification.Name("daemonNotApproved")
    /// Posted when Closed Lid activation fails visibly after the user authed
    /// (auth lockout/unavailable, daemon unreachable). userInfo["message"].
    static let closedLidActivationFailed = Notification.Name("closedLidActivationFailed")
}
