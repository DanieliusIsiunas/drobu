import SwiftUI

struct CommandOption: Identifiable {
    let id: String
    let label: String
    let icon: String?       // SF Symbol name
    let isDestructive: Bool // e.g., "Cancel" in red
}

@MainActor
protocol SlashCommand {
    var name: String { get }          // "sleep"
    var displayName: String { get }   // "Sleep Prevention"
    var icon: String { get }          // SF Symbol: "moon.zzz"
    var description: String { get }   // "Prevent your Mac from sleeping"
    var isActive: Bool { get }

    func options() -> [CommandOption]
    func execute(option: CommandOption)
    func activeStatusView() -> AnyView
}

extension SlashCommand {
    var isActive: Bool { false }
    func activeStatusView() -> AnyView { AnyView(EmptyView()) }
}
