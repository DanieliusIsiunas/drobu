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

    /// Returns true when `text` looks like hard-wrapped prose (e.g. CLI output)
    /// that should be unwrapped on capture, rather than source code, YAML, or
    /// shell. Conservative: when in doubt, return false and leave the text
    /// alone — the user can still trigger `clean` manually via the edit-mode
    /// hotkey.
    ///
    /// The heuristic is intentionally narrow. It guards against the shapes
    /// the user is most likely to copy from a terminal alongside wrapped
    /// prose: brace-block code, indented Python/Swift declarations, basic
    /// YAML maps, and basic shell control flow. It is not a complete syntax
    /// detector — exotic shapes will fall through and need manual cleanup.
    static func shouldAutoClean(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")

        // Must contain at least one wrapped continuation that `clean` would
        // actually join. `clean(text) != text` is too permissive — clean
        // also strips per-line whitespace, which would silently mangle
        // indented snippets that have nothing to unwrap.
        guard hasWrappedContinuation(in: lines) else { return false }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Brace-block opener: line ends with `{`.
            if trimmed.hasSuffix("{") { return false }

            // Brace-block closer: line consists only of closers + punctuation
            // (`}`, `})`, `};`, `},`, `])`). Prose lines that begin with `}`
            // because of a hard wrap are NOT block closers and still clean.
            if isBlockCloser(trimmed) { return false }

            // Code keyword at line start (Python def/class, Swift func, etc.).
            if startsWithCodeKeyword(trimmed) { return false }

            // Basic shell control flow.
            if isShellControlMarker(trimmed) { return false }

            // YAML nested map: `metadata:` followed by an indented `key: value`
            // line. Section headers in prose ("Note:", "Steps:") still clean
            // because their next line isn't a `key: value` pair.
            if isYAMLKey(trimmed) && nextLineLooksLikeYAMLPair(lines, after: index) {
                return false
            }
        }

        return true
    }

    // MARK: - shouldAutoClean helpers

    /// True when at least one line in `lines` would be joined into the
    /// previous line by `clean()`. Mirrors `clean()`'s join logic so the
    /// heuristic only fires on actual wrapped content, not on input whose
    /// only mutation would be whitespace stripping.
    private static func hasWrappedContinuation(in lines: [String]) -> Bool {
        var sawBlank = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                sawBlank = true
                continue
            }
            let isContinuation = !sawBlank
                && index > 0
                && line.first?.isWhitespace == true
                && !startsStructuralElement(trimmed)
            if isContinuation { return true }
            sawBlank = false
        }
        return false
    }

    private static func isBlockCloser(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "}])".contains(first) else { return false }
        let allowed: Set<Character> = ["}", "]", ")", ",", ";", " ", "\t"]
        return trimmed.allSatisfy { allowed.contains($0) }
    }

    /// Tokens that, when starting a line, strongly indicate code rather than
    /// prose. Kept narrow on purpose: words like `if`, `for`, `let`, `return`
    /// regularly start English sentences and would cause false rejections.
    private static let codeKeywordPrefixes: [String] = [
        "def ", "class ", "import ", "func ", "function",
        "const ", "package ",
    ]

    private static func startsWithCodeKeyword(_ trimmed: String) -> Bool {
        codeKeywordPrefixes.contains(where: { trimmed.hasPrefix($0) })
    }

    /// Basic shell control-flow markers: openers `; then` / `; do` and the
    /// standalone closer tokens `fi`, `done`, `esac`, `;;`. The `;` before
    /// `then`/`do` discriminates shell from English clauses ending in those
    /// words.
    private static func isShellControlMarker(_ trimmed: String) -> Bool {
        if trimmed.range(of: #";\s*(then|do)$"#, options: .regularExpression) != nil {
            return true
        }
        let closers: Set<String> = ["fi", "done", "esac", ";;"]
        return closers.contains(trimmed)
    }

    /// True when the trimmed line is a bare YAML-style key: a word token
    /// immediately followed by `:` with nothing after. Section-header prose
    /// like `Note:` also matches; callers must combine with
    /// `nextLineLooksLikeYAMLPair`.
    private static func isYAMLKey(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^[A-Za-z_][\w.-]*:$"#, options: .regularExpression) != nil
    }

    /// True when the next content line after `index` is indented and contains
    /// a `key: value` pair — the structural signature of a nested YAML map.
    private static func nextLineLooksLikeYAMLPair(_ lines: [String], after index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let next = lines[index + 1]
        guard next.first?.isWhitespace == true else { return false }
        let trimmedNext = next.trimmingCharacters(in: .whitespaces)
        return trimmedNext.range(
            of: #"(^|^- )[A-Za-z_][\w.-]*:\s+\S"#,
            options: .regularExpression
        ) != nil
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
