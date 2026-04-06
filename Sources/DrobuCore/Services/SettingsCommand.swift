import SwiftUI

@MainActor
final class SettingsCommand: SlashCommand {
    let name = "settings"
    let displayName = "Settings"
    let icon = "gearshape"
    let description = "Open Drobu preferences"

    func options() -> [CommandOption] {
        [CommandOption(id: "open", label: "Open Settings", icon: "gearshape", isDestructive: false)]
    }

    func execute(option: CommandOption) async {
        NotificationCenter.default.post(name: .openSettingsFromMenu, object: nil)
    }
}
