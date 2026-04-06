import SwiftUI

struct CommandOption: Identifiable {
    let id: String
    let label: String
    let icon: String?       // SF Symbol name
    let isDestructive: Bool // e.g., "Cancel" in red
    let section: String?    // nil = default/only section

    init(id: String, label: String, icon: String?, isDestructive: Bool, section: String? = nil) {
        self.id = id
        self.label = label
        self.icon = icon
        self.isDestructive = isDestructive
        self.section = section
    }
}

@MainActor
protocol SlashCommand {
    var name: String { get }          // "sleep"
    var displayName: String { get }   // "Sleep Prevention"
    var icon: String { get }          // SF Symbol: "moon.zzz"
    var description: String { get }   // "Prevent your Mac from sleeping"
    var isActive: Bool { get }
    var sections: [String] { get }    // empty = no sections

    func options() -> [CommandOption]
    func execute(option: CommandOption) async
    func activeStatusView() -> AnyView
}

extension SlashCommand {
    var isActive: Bool { false }
    var sections: [String] { [] }
    func activeStatusView() -> AnyView { AnyView(EmptyView()) }
}
