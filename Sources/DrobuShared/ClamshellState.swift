import Foundation

/// Pure mapping of the `AppleClamshellState` value read off `IOPMrootDomain`.
///
/// The kernel stores the property as an OSBoolean (`ioreg` *renders* it as
/// `Yes`/`No`), so the live read yields a `CFBoolean`. The string forms are
/// accepted too so the parser is robust if an OS revision ever surfaces the
/// rendered form. Anything else is `nil` — "unknown", which the edge detector
/// treats as no-change rather than guessing a lid state.
///
/// - Returns: `true` = lid closed, `false` = lid open, `nil` = unknown.
public func parseClamshellState(_ raw: Any?) -> Bool? {
    switch raw {
    case let value as Bool:
        return value
    case let value as String:
        switch value {
        case "Yes": return true
        case "No": return false
        default: return nil
        }
    default:
        return nil
    }
}

/// The lid transition a fresh clamshell reading represents.
public enum ClamshellEdge: Equatable, Sendable {
    case closed   // open → closed: fire display-off
    case opened   // closed → open: lid/HID wake restores the panel
}

/// Edge-triggers lid transitions from a stream of polled clamshell readings,
/// so the display-off action fires exactly once per physical close — not on
/// every 500ms tick while the lid stays shut.
///
/// The first definitive reading establishes a baseline WITHOUT firing an edge:
/// if a session starts (or rehydrates) with the lid already closed — e.g.
/// clamshell mode on an external display — firing display-off then would blank
/// the display the user is actively looking at. `nil` (unknown) readings never
/// move the baseline and never fire.
public struct ClamshellEdgeDetector: Sendable {
    private var isLidClosed: Bool?

    public init() {}

    /// Feed one polled reading; returns the edge it represents, if any.
    public mutating func ingest(_ reading: Bool?) -> ClamshellEdge? {
        guard let reading else { return nil }
        defer { isLidClosed = reading }
        guard let previous = isLidClosed, previous != reading else { return nil }
        return reading ? .closed : .opened
    }
}
