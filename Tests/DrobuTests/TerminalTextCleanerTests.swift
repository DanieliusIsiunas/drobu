import Testing
import Foundation
@testable import DrobuCore

@Suite("TerminalTextCleaner")
struct TerminalTextCleanerTests {

    // MARK: - clean()

    @Test func cleanUnwrapsContinuationLines() {
        let input = "This is a long line\n    that continues here"
        let result = TerminalTextCleaner.clean(input)
        #expect(result == "This is a long line that continues here")
    }

    @Test func cleanPreservesParagraphBreaks() {
        let input = "Paragraph one.\n\nParagraph two."
        let result = TerminalTextCleaner.clean(input)
        #expect(result == "Paragraph one.\n\nParagraph two.")
    }

    @Test(
        "Structural elements are not joined as continuations",
        arguments: [
            ("Header:\n  1. First item", "Header:\n1. First item"),
            ("Header:\n  - Bullet item", "Header:\n- Bullet item"),
            ("Header:\n  * Star bullet", "Header:\n* Star bullet"),
            ("Header:\n  # Heading", "Header:\n# Heading"),
            ("Header:\n  ## Subheading", "Header:\n## Subheading"),
        ]
    )
    func cleanDetectsStructuralElements(input: String, expected: String) {
        let result = TerminalTextCleaner.clean(input)
        #expect(result == expected)
    }

    @Test func cleanSingleLineIsNoOp() {
        let input = "just a single line"
        let result = TerminalTextCleaner.clean(input)
        #expect(result == input)
    }

    // MARK: - stripANSI()

    @Test func stripANSIRemovesCSIColorCodes() {
        let input = "\u{1B}[31mred text\u{1B}[0m"
        let result = TerminalTextCleaner.stripANSI(input)
        #expect(result == "red text")
    }

    @Test func stripANSIRemovesOSCSequences() {
        // BEL-terminated OSC
        let belInput = "\u{1B}]0;window title\u{07}actual text"
        #expect(TerminalTextCleaner.stripANSI(belInput) == "actual text")

        // ST-terminated OSC
        let stInput = "\u{1B}]0;window title\u{1B}\\actual text"
        #expect(TerminalTextCleaner.stripANSI(stInput) == "actual text")
    }

    @Test func stripANSIPassesThroughCleanText() {
        let input = "no escape sequences here"
        #expect(TerminalTextCleaner.stripANSI(input) == input)
    }
}
