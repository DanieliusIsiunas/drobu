import Combine
import Foundation

/// The sidebar sections of the unified Settings panel, in display order.
/// `allCases` order IS the sidebar order — Set Up first (the first-run landing),
/// then the ongoing-settings sections.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case setUp
    case shortcuts
    case history
    case license
    case about

    var id: String { rawValue }

    /// Sidebar row label.
    var title: String {
        switch self {
        case .setUp: return "Set Up"
        case .shortcuts: return "Shortcuts"
        case .history: return "History"
        case .license: return "License"
        case .about: return "About"
        }
    }

    /// SF Symbol shown beside the row label.
    var symbolName: String {
        switch self {
        case .setUp: return "sparkles"
        case .shortcuts: return "command"
        case .history: return "clock.arrow.circlepath"
        case .license: return "key"
        case .about: return "info.circle"
        }
    }
}

/// The section the panel opens to given the run mode. First run lands on Set Up
/// (the welcome + permission checklist); ongoing opens to Shortcuts (Set Up is
/// then just a revisitable section).
func landingSection(firstRun: Bool) -> SettingsSection {
    firstRun ? .setUp : .shortcuts
}

/// Whether the welcome header + "Start using Drobu" CTA chrome shows for a
/// section. Only Set Up on first run — every other section, and Set Up when
/// revisited later, shows plain content with no welcome/CTA.
func showsWelcomeChrome(in section: SettingsSection, firstRun: Bool) -> Bool {
    firstRun && section == .setUp
}

/// Drives the sidebar: which section is currently selected. Pure logic over the
/// section enum, separated from SwiftUI so landing/chrome decisions are
/// unit-testable (mirrors `OnboardingViewModel`).
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selected: SettingsSection

    init(firstRun: Bool) {
        self.selected = landingSection(firstRun: firstRun)
    }

    /// Sidebar sections in display order.
    var sections: [SettingsSection] { SettingsSection.allCases }

    /// Position of `selected` within `sections`.
    private var selectedIndex: Int {
        sections.firstIndex(of: selected) ?? 0
    }

    /// Move selection one section down, clamping at the last (no wrap).
    func selectNext() {
        let next = selectedIndex + 1
        if next < sections.count { selected = sections[next] }
    }

    /// Move selection one section up, clamping at the first (no wrap).
    func selectPrevious() {
        let previous = selectedIndex - 1
        if previous >= 0 { selected = sections[previous] }
    }

    /// Jump to a section by its 1-based sidebar position (1 = first section).
    /// Out-of-range numbers are ignored, so unmapped digit keys are harmless.
    func select(number: Int) {
        let index = number - 1
        guard sections.indices.contains(index) else { return }
        selected = sections[index]
    }
}
