import Foundation

/// Parse the `SleepDisabled` value out of `pmset -g` output.
///
/// Review finding M1: the inherited check (`output.contains("SleepDisabled")
/// && output.contains("1")`) false-positives whenever any *other* line carries
/// a `1` — e.g. `standby 1` while `SleepDisabled 0` reads as TRUE. The daemon's
/// reconciliation table ("state absent, SleepDisabled on → orphan → reverse")
/// rests on this read, so it parses the `SleepDisabled` line's OWN value.
public func parseSleepDisabled(fromPmsetG output: String) -> Bool {
    for rawLine in output.split(whereSeparator: \.isNewline) {
        let fields = rawLine.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
        return fields[1] == "1"
    }
    return false
}
