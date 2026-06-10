import Testing
@testable import DrobuCore
import DrobuShared

/// Pins the `ClosedLidError` → user-facing route mapping that `SleepCommand`
/// dispatches on (silent / guidance / visible / log). A dedicated suite rather
/// than overloading the formatting-scoped `SleepCommandFormattingTests`.
@Suite("ClosedLidError routing")
struct SleepCommandErrorMappingTests {

    @Test("user cancel is silent")
    func cancelSilent() {
        #expect(ClosedLidError.authCancelled.route == .silent)
    }

    @Test("not-approved routes to guidance")
    func notApprovedGuidance() {
        #expect(ClosedLidError.daemonNotApproved.route == .guidance)
    }

    @Test("protocol mismatch routes to guidance")
    func mismatchGuidance() {
        #expect(ClosedLidError.protocolMismatch.route == .guidance)
    }

    @Test("auth failure surfaces a visible failure carrying the reason")
    func authFailedVisible() {
        #expect(ClosedLidError.authFailed("locked out").route == .visibleFailure("locked out"))
    }

    @Test("daemon unavailable surfaces a visible failure with its message")
    func unavailableVisible() {
        #expect(ClosedLidError.daemonUnavailable.route == .visibleFailure("Closed Lid helper is unavailable."))
    }

    @Test("a daemon-side validation rejection surfaces a visible failure with its message")
    func rejectedVisible() {
        #expect(ClosedLidError.enableRejected(.durationNotAllowed).route
                == .visibleFailure("Closed Lid couldn't be activated right now."))
    }
}
