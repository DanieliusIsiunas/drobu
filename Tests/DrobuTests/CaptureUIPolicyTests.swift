import Testing
@testable import DrobuCore

@Suite("CaptureUIPolicy")
struct CaptureUIPolicyTests {

    private static let allGifStates: [ScreenCaptureService.State] = [
        .idle, .selecting, .recording, .encoding,
    ]
    private static let allVideoStates: [VideoCaptureService.State] = [
        .idle, .selecting, .recording, .finalizing,
    ]

    // MARK: - Esc claim

    @Test func escClaimActiveWhenGifRecordingAndVideoIdle() {
        #expect(CaptureUIPolicy.escClaimActive(gif: .recording, video: .idle))
    }

    @Test func escClaimActiveWhenVideoRecordingAndGifIdle() {
        #expect(CaptureUIPolicy.escClaimActive(gif: .idle, video: .recording))
    }

    @Test func escClaimInactiveWhenBothIdle() {
        #expect(!CaptureUIPolicy.escClaimActive(gif: .idle, video: .idle))
    }

    @Test func escClaimInactiveDuringGifSelectingAndEncoding() {
        #expect(!CaptureUIPolicy.escClaimActive(gif: .selecting, video: .idle))
        #expect(!CaptureUIPolicy.escClaimActive(gif: .encoding, video: .idle))
    }

    @Test func escClaimInactiveDuringVideoSelectingAndFinalizing() {
        #expect(!CaptureUIPolicy.escClaimActive(gif: .idle, video: .selecting))
        #expect(!CaptureUIPolicy.escClaimActive(gif: .idle, video: .finalizing))
    }

    // Explicit truth table over all 16 state combinations: the claim is active
    // iff either service is actively recording. Driven by allGifStates ×
    // allVideoStates so a new enum case omitted from the state arrays fails the
    // count guard below rather than silently escaping coverage.
    static let escClaimMatrix: [(ScreenCaptureService.State, VideoCaptureService.State, Bool)] = [
        (.idle, .idle, false),
        (.idle, .selecting, false),
        (.idle, .recording, true),
        (.idle, .finalizing, false),
        (.selecting, .idle, false),
        (.selecting, .selecting, false),
        (.selecting, .recording, true),
        (.selecting, .finalizing, false),
        (.recording, .idle, true),
        (.recording, .selecting, true),
        (.recording, .recording, true),
        (.recording, .finalizing, true),
        (.encoding, .idle, false),
        (.encoding, .selecting, false),
        (.encoding, .recording, true),
        (.encoding, .finalizing, false),
    ]

    @Test func escClaimMatrixCoversEveryStateCombination() {
        #expect(Self.escClaimMatrix.count == Self.allGifStates.count * Self.allVideoStates.count)
    }

    @Test(arguments: escClaimMatrix)
    func escClaimActiveMatchesTruthTable(
        gif: ScreenCaptureService.State,
        video: VideoCaptureService.State,
        expected: Bool
    ) {
        #expect(CaptureUIPolicy.escClaimActive(gif: gif, video: video) == expected)
    }

    // MARK: - Panel toggle gate

    @Test func panelAllowedWhenBothIdle() {
        #expect(CaptureUIPolicy.panelToggleAllowed(gif: .idle, video: .idle))
    }

    @Test func panelAllowedDuringGifRecording() {
        #expect(CaptureUIPolicy.panelToggleAllowed(gif: .recording, video: .idle))
    }

    @Test func panelAllowedDuringVideoRecording() {
        #expect(CaptureUIPolicy.panelToggleAllowed(gif: .idle, video: .recording))
    }

    @Test func panelBlockedDuringGifSelectingAndEncoding() {
        #expect(!CaptureUIPolicy.panelToggleAllowed(gif: .selecting, video: .idle))
        #expect(!CaptureUIPolicy.panelToggleAllowed(gif: .encoding, video: .idle))
    }

    @Test func panelBlockedDuringVideoSelectingAndFinalizing() {
        #expect(!CaptureUIPolicy.panelToggleAllowed(gif: .idle, video: .selecting))
        #expect(!CaptureUIPolicy.panelToggleAllowed(gif: .idle, video: .finalizing))
    }

    // Explicit truth table over all 16 state combinations:
    // allowed iff both services are in { idle, recording }.
    static let panelToggleMatrix: [(ScreenCaptureService.State, VideoCaptureService.State, Bool)] = [
        (.idle, .idle, true),
        (.idle, .selecting, false),
        (.idle, .recording, true),
        (.idle, .finalizing, false),
        (.selecting, .idle, false),
        (.selecting, .selecting, false),
        (.selecting, .recording, false),
        (.selecting, .finalizing, false),
        (.recording, .idle, true),
        (.recording, .selecting, false),
        (.recording, .recording, true),
        (.recording, .finalizing, false),
        (.encoding, .idle, false),
        (.encoding, .selecting, false),
        (.encoding, .recording, false),
        (.encoding, .finalizing, false),
    ]

    @Test func panelToggleMatrixCoversEveryStateCombination() {
        #expect(Self.panelToggleMatrix.count == Self.allGifStates.count * Self.allVideoStates.count)
    }

    @Test(arguments: panelToggleMatrix)
    func panelToggleAllowedMatchesTruthTable(
        gif: ScreenCaptureService.State,
        video: VideoCaptureService.State,
        expected: Bool
    ) {
        #expect(CaptureUIPolicy.panelToggleAllowed(gif: gif, video: video) == expected)
    }
}
