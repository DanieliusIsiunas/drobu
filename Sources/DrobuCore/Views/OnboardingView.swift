import SwiftUI

/// The first-launch permission checklist shown inside `OnboardingPanel`. A
/// single screen: a warm welcome, a Required tier and an Optional tier of
/// permission rows with live status, and a footer that names the next action.
/// Nothing is forced — "Skip for now" is always available, and optional rows
/// can be left untouched.
///
/// Action invocation is delegated up via `onAction` (the panel performs it
/// against the real APIs — system boundary); the row/completion logic lives in
/// `OnboardingViewModel` (unit-tested).
struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel
    var onAction: (OnboardingAction) -> Void
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Required", rows: model.requiredRows)
                    section("Optional — set up anytime", rows: model.optionalRows)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            footer
        }
        .frame(width: 480, height: 600)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Let's get Drobu comfortable on your Mac")
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Grant a couple of permissions and you're off — most take one click.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        // .ignore + explicit label, not .combine — .combine concatenates the two
        // Texts unpredictably (project a11y rule).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Let's get Drobu comfortable on your Mac. Grant a couple of permissions and you're off — most take one click.")
    }

    // MARK: - Sections / rows

    @ViewBuilder
    private func section(_ title: String, rows: [OnboardingRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ForEach(rows) { row in rowView(row) }
            }
        }
    }

    private func rowView(_ row: OnboardingRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph(row.state)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)   // decorative — status is spoken in the label below
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Group ONLY the title/subtitle into the label element. The action
            // control stays a SEPARATE focusable element so VoiceOver can still
            // reach Open Settings / Enable / Restart / the toggle — collapsing the
            // whole row with children:.ignore would suppress that primary action
            // (the row carries no action of its own; the control does).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.title): \(accessibilityStatus(row.state))")
            .accessibilityHint(row.subtitle)
            Spacer(minLength: 8)
            actionControl(for: row)
        }
    }

    @ViewBuilder
    private func statusGlyph(_ state: PermissionState) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .pendingRestart:
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
        case .notGranted, .notApplicable:
            Image(systemName: "circle").foregroundStyle(.secondary.opacity(0.5))
        }
    }

    @ViewBuilder
    private func actionControl(for row: OnboardingRow) -> some View {
        if row.permission == .launchAtLogin {
            // Rendered as a toggle, bound to the live state.
            Toggle("", isOn: Binding(
                get: { row.state == .granted },
                set: { onAction(.toggleLaunchAtLogin(enable: $0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Launch at login")
        } else if let action = row.primaryAction {
            Text(actionLabel(for: action))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(action == .restart ? Color.orange : Color.accentColor)
                .contentShape(Rectangle())
                .onTapGesture { onAction(action) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(actionLabel(for: action))
                .accessibilityAddTraits(.isButton)
        } else {
            Text("Ready")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
    }

    private func actionLabel(for action: OnboardingAction) -> String {
        switch action {
        case .openAccessibilitySettings, .openScreenRecordingSettings, .openPasteboardSettings:
            return "Open Settings"
        case .enableClosedLidHelper:
            return "Enable"
        case .restart:
            return "Restart to activate"
        case .toggleLaunchAtLogin:
            return "Toggle launch at login"
        }
    }

    private func accessibilityStatus(_ state: PermissionState) -> String {
        switch state {
        case .granted: return "ready"
        case .pendingRestart: return "granted, restart to activate"
        case .notGranted: return "not set up"
        case .notApplicable: return "not applicable"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                // Decorative hint — the button below carries the actionable
                // state for VoiceOver, so this would just be redundant chatter.
                .accessibilityHidden(true)

            primaryButton

            // Escape hatch while a restart is pending — nothing is forced. The
            // user can dismiss without restarting; paste degrades gracefully
            // (copying still works) until they relaunch.
            if model.completion == .pendingRestart {
                Text("Skip for now")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { onFinish() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Skip onboarding for now")
            }
        }
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var footerHint: String {
        switch model.completion {
        case .ready:
            return "You're all set — copy something and press your hotkey to try it."
        case .pendingRestart:
            return "One quick restart and Drobu can paste anywhere — your history is safe."
        case .incomplete:
            return "Set up the required ones and you're ready. The rest can wait."
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.completion {
        case .ready:
            footerButton(title: "Start using Drobu", filled: true, tint: .accentColor,
                         label: "Start using Drobu") { onFinish() }
        case .pendingRestart:
            // Honest completion: paste won't work until relaunch, so the primary
            // action restarts rather than claiming "all set".
            footerButton(title: "Restart to activate", filled: true, tint: .orange,
                         label: "Restart Drobu to activate permissions") { onAction(.restart) }
        case .incomplete:
            footerButton(title: "Skip for now", filled: false, tint: .accentColor,
                         label: "Skip onboarding for now") { onFinish() }
        }
    }

    private func footerButton(title: String, filled: Bool, tint: Color, label: String,
                              action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? tint : tint.opacity(0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .padding(.horizontal, 24)
    }
}
