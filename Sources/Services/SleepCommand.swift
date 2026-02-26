import SwiftUI

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

    var isActive: Bool { service.isActive }

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

    func activeStatusView() -> AnyView {
        guard service.isActive, let remaining = service.remainingTime else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Sleep Prevention Active")
                    .font(.headline)
                    .foregroundStyle(.primary)
                // TimelineView polls every 1s — CaffeinateService is not @Observable,
                // so reactive observation is not available. Do not remove the TimelineView wrapper.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let secs = self.service.remainingTime ?? remaining
                    Text(SleepCommand.formatDuration(secs))
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        )
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
