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

    // MARK: - shouldAutoClean()

    @Test func shouldAutoCleanAcceptsWrappedProse() {
        let input = "This is a long line of CLI output\n  that wraps onto the next line\n  and continues here"
        #expect(TerminalTextCleaner.shouldAutoClean(input) == true)
    }

    @Test func shouldAutoCleanSkipsAlreadyClean() {
        #expect(TerminalTextCleaner.shouldAutoClean("Already clean text without continuations.") == false)
    }

    @Test(
        "Inputs that only need whitespace stripping are not auto-cleaned",
        arguments: [
            // Single indented line — no continuation to unwrap.
            "    return value",
            // Trailing whitespace only.
            "hello world   ",
            // Two indented lines separated by a blank — no continuation crosses the gap.
            "    line one\n\n    line two",
        ]
    )
    func shouldAutoCleanSkipsWhenNoContinuation(input: String) {
        #expect(TerminalTextCleaner.shouldAutoClean(input) == false)
    }

    @Test(
        "Code-shaped content is rejected",
        arguments: [
            // Brace-block code (Swift / JS / C / CSS)
            "func foo() {\n    return 1\n}",
            "{\n  \"key\": \"value\"\n}",
            ".foo {\n  color: red\n}",
            // Indentation-significant declarations
            "def my_func():\n    return 1",
            "class Foo:\n    pass",
            "import Foundation\n  more text",
            "const x = 5\n  continuation",
            "function bar()\n  body",
            // Block-closer continuation lines
            "doSomething\n})",
            "doSomething\n};",
        ]
    )
    func shouldAutoCleanRejectsCode(input: String) {
        #expect(TerminalTextCleaner.shouldAutoClean(input) == false)
    }

    @Test(
        "YAML nested maps are rejected",
        arguments: [
            "metadata:\n  name: foo",
            "spec:\n  containers:\n    - name: app",
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: bar\n  namespace: default",
        ]
    )
    func shouldAutoCleanRejectsYAML(input: String) {
        #expect(TerminalTextCleaner.shouldAutoClean(input) == false)
    }

    @Test(
        "Basic shell control-flow blocks are rejected",
        arguments: [
            "if [ -f \"$file\" ]; then\n  echo hi\nfi",
            "for x in *; do\n  echo $x\ndone",
            "while true; do\n  sleep 1\ndone",
        ]
    )
    func shouldAutoCleanRejectsShellControl(input: String) {
        #expect(TerminalTextCleaner.shouldAutoClean(input) == false)
    }

    @Test func shouldAutoCleanAcceptsProseWithSectionHeader() {
        // A prose section header like `Note:` looks syntactically like a YAML
        // key, but the indented continuation is plain prose, not a `key: value`
        // pair. Must still be cleaned.
        let input = "Note:\n  this paragraph wraps onto the next line\n  and continues here."
        #expect(TerminalTextCleaner.shouldAutoClean(input) == true)
    }

    @Test func shouldAutoCleanAcceptsProseMentioningCodeChars() {
        // Prose discussing code by literal characters should still clean —
        // `{`, `}`, and `;` appearing inside prose are not structural code.
        let input = """
        - shouldAutoClean(_:) — heuristic that returns true only when text has \
        unwrappable continuations AND no {, }, ;, and no line starts with code \
        keywords (def, class, func, etc.).
        - extractRecord — runs clean() automatically when the heuristic passes;
          logs auto-cleaned wrapped text from <app> so you can verify.
        """
        #expect(TerminalTextCleaner.shouldAutoClean(input) == true)
    }

    @Test func shouldAutoCleanAcceptsProseWrappedAtCodeMention() {
        // A continuation line that happens to begin with `}` because the
        // sentence wrapped at a code mention is NOT a block closer.
        let input = """
        We support the characters {, }, and ; inside prose, plus mentions of
          }, or ; inside prose no longer trigger a skip.
        """
        #expect(TerminalTextCleaner.shouldAutoClean(input) == true)
    }

    @Test func shouldAutoCleanAcceptsSemicolonInProse() {
        let input = "The build passes; it then ships to production\n  with no further intervention."
        #expect(TerminalTextCleaner.shouldAutoClean(input) == true)
    }

    @Test func shouldAutoCleanAcceptsCLIOutputWithBullets() {
        let input = "Here is the result of running your command\n  with some wrapped explanation\n\n- item one\n- item two"
        #expect(TerminalTextCleaner.shouldAutoClean(input) == true)
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
