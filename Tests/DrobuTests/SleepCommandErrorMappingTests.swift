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

    @Test("protocol mismatch (post-reinstall residual) is a visible failure, NOT approval guidance")
    func mismatchVisible() {
        // The approval alert would be a lie here — the helper is approved; its
        // stale process just survived the reinstall attempt.
        #expect(ClosedLidError.protocolMismatch.route
                == .visibleFailure("Closed Lid helper is still updating — try again in a moment."))
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
