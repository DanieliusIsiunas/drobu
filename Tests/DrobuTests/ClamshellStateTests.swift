import Foundation
import Testing
@testable import DrobuShared

@Suite("ClamshellState parsing")
struct ClamshellStateParsingTests {
    @Test("boolean property values (the real IORegistry form) map directly")
    func booleanForms() {
        #expect(parseClamshellState(true) == true)
        #expect(parseClamshellState(false) == false)
        // The live read yields CFBoolean; it bridges through Any as Bool.
        #expect(parseClamshellState(kCFBooleanTrue as Any) == true)
        #expect(parseClamshellState(kCFBooleanFalse as Any) == false)
    }

    @Test("rendered string forms map exactly, case-sensitively")
    func stringForms() {
        #expect(parseClamshellState("Yes") == true)
        #expect(parseClamshellState("No") == false)
        #expect(parseClamshellState("yes") == nil)
        #expect(parseClamshellState("no") == nil)
        #expect(parseClamshellState("") == nil)
        #expect(parseClamshellState("1") == nil)
    }

    @Test("missing or alien values are unknown, never a guessed lid state")
    func unknownForms() {
        #expect(parseClamshellState(nil) == nil)
        #expect(parseClamshellState(Data()) == nil)
        #expect(parseClamshellState(["Yes"]) == nil)
    }
}

@Suite("ClamshellEdgeDetector")
struct ClamshellEdgeDetectorTests {
    @Test("open → closed fires exactly one .closed edge")
    func closeEdgeFiresOnce() {
        var detector = ClamshellEdgeDetector()
        #expect(detector.ingest(false) == nil)     // baseline: open, no edge
        #expect(detector.ingest(true) == .closed)  // the close edge
        #expect(detector.ingest(true) == nil)      // staying closed: no re-fire
        #expect(detector.ingest(true) == nil)
    }

    @Test("closed → open fires exactly one .opened edge")
    func openEdgeFiresOnce() {
        var detector = ClamshellEdgeDetector()
        #expect(detector.ingest(false) == nil)
        #expect(detector.ingest(true) == .closed)
        #expect(detector.ingest(false) == .opened)
        #expect(detector.ingest(false) == nil)     // staying open: no re-fire
    }

    @Test("the first definitive reading is a baseline, not an edge — even closed")
    func baselineNeverFires() {
        // Session starting with the lid already closed (clamshell mode on an
        // external display) must NOT blank the display the user is looking at.
        var closedStart = ClamshellEdgeDetector()
        #expect(closedStart.ingest(true) == nil)
        #expect(closedStart.ingest(true) == nil)
        #expect(closedStart.ingest(false) == .opened)   // a real transition still fires

        var openStart = ClamshellEdgeDetector()
        #expect(openStart.ingest(false) == nil)
    }

    @Test("unknown readings never fire and never move the baseline")
    func unknownReadingsAreInert() {
        var detector = ClamshellEdgeDetector()
        #expect(detector.ingest(nil) == nil)            // unknown before baseline
        #expect(detector.ingest(false) == nil)          // baseline: open
        #expect(detector.ingest(nil) == nil)            // unknown mid-stream
        #expect(detector.ingest(true) == .closed)       // edge vs the last GOOD reading
        #expect(detector.ingest(nil) == nil)
        #expect(detector.ingest(true) == nil)           // unknown didn't reset the state
        #expect(detector.ingest(false) == .opened)
    }

    @Test("a full close/open/close cycle fires three edges in order")
    func fullCycle() {
        var detector = ClamshellEdgeDetector()
        var edges: [ClamshellEdge] = []
        for reading in [false, true, true, false, true] {
            if let edge = detector.ingest(reading) { edges.append(edge) }
        }
        #expect(edges == [.closed, .opened, .closed])
    }
}
