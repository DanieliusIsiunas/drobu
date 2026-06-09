import SwiftUI

@MainActor
final class SleepCommand: SlashCommand {
    let name = "sleep"
    let displayName = "Sleep Prevention"
    let icon = "moon.zzz"
    let description = "Prevent your Mac from sleeping"

    private let caffeinateService: CaffeinateService
    private let closedLidService: ClosedLidService

    init(caffeinateService: CaffeinateService, closedLidService: ClosedLidService) {
        self.caffeinateService = caffeinateService
        self.closedLidService = closedLidService
    }

    let sections = ["Keep Awake", "Closed Lid"]

    var isActive: Bool {
        caffeinateService.isActive || closedLidService.isActive
    }

    /// Returns the section name of the currently active mode, or nil if idle.
    var activeSectionName: String? {
        if closedLidService.isActive { return "Closed Lid" }
        if caffeinateService.isActive { return "Keep Awake" }
        return nil
    }

    func options() -> [CommandOption] {
        var opts: [CommandOption] = []

        // Keep Awake section
        if caffeinateService.isActive {
            opts.append(CommandOption(
                id: "ka-cancel",
                label: "Stop Keep Awake",
                icon: "stop.circle",
                isDestructive: true,
                section: "Keep Awake"
            ))
        }

        for item in Self.durations {
            opts.append(CommandOption(
                id: "ka-\(item.id)",
                label: item.label,
                icon: "clock",
                isDestructive: false,
                section: "Keep Awake"
            ))
        }

        // Closed Lid section
        if closedLidService.isActive {
            opts.append(CommandOption(
                id: "cl-cancel",
                label: "Stop Closed Lid",
                icon: "stop.circle",
                isDestructive: true,
                section: "Closed Lid"
            ))
        }

        for item in Self.durations {
            opts.append(CommandOption(
                id: "cl-\(item.id)",
                label: item.label,
                icon: "clock",
                isDestructive: false,
                section: "Closed Lid"
            ))
        }

        return opts
    }

    func execute(option: CommandOption) async {
        let id = option.id

        // Keep Awake actions
        if id == "ka-cancel" {
            caffeinateService.stop()
            return
        }
        if id.hasPrefix("ka-"), let duration = Self.parseDuration(id: String(id.dropFirst(3))) {
            // Mutual exclusion: stop Closed Lid first (confirmed-by-readback).
            if closedLidService.isActive { await closedLidService.stop() }
            caffeinateService.start(duration: duration)
            return
        }

        // Closed Lid actions
        if id == "cl-cancel" {
            await closedLidService.stop()
            return
        }
        if id.hasPrefix("cl-"), let duration = Self.parseDuration(id: String(id.dropFirst(3))) {
            // Mutual exclusion: stop Keep Awake first
            if caffeinateService.isActive { caffeinateService.stop() }
            do {
                try await closedLidService.start(duration: duration)
            } catch let error as ClosedLidError {
                SleepCommand.handle(error)
            } catch {
                Log.error("SleepCommand: unexpected Closed Lid error: \(error)")
            }
            return
        }
    }

    /// Routes a `ClosedLidError` to its user-facing surface (the route mapping
    /// itself lives on `ClosedLidError`; this performs the side effect). Unit
    /// tested in `SleepCommandErrorMappingTests`.
    static func handle(_ error: ClosedLidError) {
        switch error.route {
        case .silent:
            Log.info("SleepCommand: Closed Lid activation cancelled")
        case .guidance:
            NotificationCenter.default.post(name: .daemonNotApproved, object: nil)
        case .visibleFailure(let message):
            NotificationCenter.default.post(
                name: .closedLidActivationFailed, object: nil, userInfo: ["message": message])
        }
    }

    func activeStatusView() -> AnyView {
        if closedLidService.isActive {
            return AnyView(statusView(
                icon: "laptopcomputer.slash",
                title: "Closed Lid Mode",
                service: .closedLid
            ))
        }
        if caffeinateService.isActive {
            return AnyView(statusView(
                icon: "moon.zzz",
                title: "Keep Awake",
                service: .keepAwake
            ))
        }
        return AnyView(EmptyView())
    }

    // MARK: - Private

    private enum ActiveService { case keepAwake, closedLid }

    private func remainingForService(_ service: ActiveService) -> TimeInterval {
        switch service {
        case .keepAwake: return caffeinateService.remainingTime ?? 0
        case .closedLid: return closedLidService.remainingTime ?? 0
        }
    }

    private func statusView(icon: String, title: String, service: ActiveService) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            // TimelineView polls every 1s — services are not @Observable,
            // so reactive observation is not available.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.formatDuration(self.remainingForService(service)))
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
    }

    private static let durations: [(id: String, label: String, seconds: TimeInterval)] = [
        ("15m", "15 minutes", 15 * 60),
        ("30m", "30 minutes", 30 * 60),
        ("1h", "1 hour", 60 * 60),
        ("2h", "2 hours", 2 * 60 * 60),
        ("4h", "4 hours", 4 * 60 * 60),
    ]

    private static func parseDuration(id: String) -> TimeInterval? {
        durations.first(where: { $0.id == id })?.seconds
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

    /// Human phrasing for the menu bar status line, including the trailing
    /// "left" (e.g. "23 min left", "1 hr 5 min left"). Floors to whole minutes.
    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        if totalMinutes < 1 { return "< 1 min left" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(m) min left" }
        if m == 0 { return "\(h) hr left" }
        return "\(h) hr \(m) min left"
    }
}
