/// Pure decision logic for capture-related UI gating.
///
/// AppDelegate consumes these predicates to decide when the transient global
/// plain-Esc stop hotkey is registered and when the panel hotkey is allowed
/// to toggle the main panel. Pure functions over the two capture services'
/// states — no AppKit, no service references — so the logic is unit-testable
/// while the AppKit wiring in AppDelegate stays out of test scope.
enum CaptureUIPolicy {

    /// The global plain-Esc stop hotkey is claimed only while a recording is
    /// actively running. Never during region selection (the selection panel
    /// handles Esc locally), encoding/finalizing (recording already ended),
    /// or idle — so Esc behaves normally everywhere else system-wide.
    static func escClaimActive(
        gif: ScreenCaptureService.State,
        video: VideoCaptureService.State
    ) -> Bool {
        gif == .recording || video == .recording
    }

    /// The main panel may toggle while both services are idle (normal use)
    /// or while a recording is running (so Drobu can record its own UI).
    /// Blocked during region selection (the overlay owns the screen) and
    /// during encoding/finalizing (brief transition out of capture).
    static func panelToggleAllowed(
        gif: ScreenCaptureService.State,
        video: VideoCaptureService.State
    ) -> Bool {
        let gifAllows = gif == .idle || gif == .recording
        let videoAllows = video == .idle || video == .recording
        return gifAllows && videoAllows
    }
}
