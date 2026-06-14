import Foundation

public extension Notification.Name {
    /// Posted by the `/settings` slash command to open the unified Settings
    /// panel. AppDelegate owns the panel and observes this (a service can't reach
    /// the delegate directly). The status-menu "Settings…" item calls the
    /// delegate directly and does not need this.
    static let openSettingsFromMenu = Notification.Name("openSettingsFromMenu")
    /// Posted when Closed Lid activation needs the daemon registered/approved.
    /// AppDelegate turns it into an NSAlert with an "Open System Settings"
    /// action (the Settings scene's `.alert` does not fire — see swiftui rules).
    static let daemonNotApproved = Notification.Name("daemonNotApproved")
    /// Posted when Closed Lid activation fails visibly after the user authed
    /// (auth lockout/unavailable, daemon unreachable). userInfo["message"].
    static let closedLidActivationFailed = Notification.Name("closedLidActivationFailed")
}
