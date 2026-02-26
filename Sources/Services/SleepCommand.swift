import Foundation

@MainActor
final class SleepCommand: SlashCommand {
    let name = "sleep"
    let displayName = "Sleep Prevention"
    let icon = "moon.zzz"
    let description = "Prevent your Mac from sleeping"

    private let service: CaffeinateService

    init(service: CaffeinateService) {
        self.service = service
    }

    func options() -> [CommandOption] {
        var opts: [CommandOption] = []

        if service.isActive {
            opts.append(CommandOption(
                id: "cancel",
                label: "Stop Sleep Prevention",
                icon: "stop.circle",
                isDestructive: true
            ))
        }

        opts.append(contentsOf: [
            CommandOption(id: "15m", label: "15 minutes", icon: "clock", isDestructive: false),
            CommandOption(id: "30m", label: "30 minutes", icon: "clock", isDestructive: false),
            CommandOption(id: "1h", label: "1 hour", icon: "clock", isDestructive: false),
            CommandOption(id: "2h", label: "2 hours", icon: "clock", isDestructive: false),
            CommandOption(id: "4h", label: "4 hours", icon: "clock", isDestructive: false),
        ])

        return opts
    }

    func execute(option: CommandOption) {
        switch option.id {
        case "cancel": service.stop()
        case "15m":    service.start(duration: 15 * 60)
        case "30m":    service.start(duration: 30 * 60)
        case "1h":     service.start(duration: 60 * 60)
        case "2h":     service.start(duration: 2 * 60 * 60)
        case "4h":     service.start(duration: 4 * 60 * 60)
        default: break
        }
    }
}
