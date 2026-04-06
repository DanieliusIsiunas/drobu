import Foundation

/// Unwraps hard-wrapped text by joining continuation lines and removing blank lines.
/// Continuation = a line starting with whitespace that follows a non-blank line
/// without a blank-line gap. Blank lines act as paragraph separators that prevent joining.
enum TerminalTextCleaner {

    static func clean(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var sawBlank = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank lines: remember we saw one (prevents continuation joining)
            if trimmed.isEmpty {
                sawBlank = true
                continue
            }

            // Emit a blank line separator if we crossed a paragraph break
            if sawBlank && !result.isEmpty {
                result.append("")
            }

            // A line is a continuation only if:
            // - no blank line gap before it
            // - starts with whitespace
            // - doesn't start a new structural element (list item, heading)
            let isContinuation = !sawBlank
                && !result.isEmpty
                && line.first?.isWhitespace == true
                && !startsStructuralElement(trimmed)

            if isContinuation {
                result[result.count - 1] += " " + trimmed
            } else {
                result.append(trimmed)
            }

            sawBlank = false
        }

        return result.joined(separator: "\n")
    }

    /// Strip ANSI escape sequences (CSI, OSC) from text.
    static func stripANSI(_ text: String) -> String {
        // CSI: \x1B[ followed by parameter bytes and a letter
        // OSC: \x1B] followed by content terminated by BEL (\x07) or ST (\x1B\\)
        text.replacingOccurrences(
            of: "\u{1B}(?:\\[[0-9;]*[A-Za-z]|\\][^\u{07}]*(?:\u{07}|\u{1B}\\\\))",
            with: "",
            options: .regularExpression
        )
    }

    /// Detect lines that start a new structural element (not a continuation).
    private static func startsStructuralElement(_ trimmed: String) -> Bool {
        // Numbered list: "1. ", "2. ", "10. ", etc.
        if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            return true
        }
        // Bullet list: "- " or "* "
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return true
        }
        // Heading: "# ", "## ", etc.
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
            return true
        }
        return false
    }
}
