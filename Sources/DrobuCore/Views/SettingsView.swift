import SwiftUI
import HotKey
import ServiceManagement
import Combine

public struct SettingsView: View {
    @State private var launchAtLogin = MainAppLaunchAgentControl().isEnabled
    @State private var hotkeyCombo: KeyCombo? = HotkeyDefaults.load()
    @State private var captureHotkeyCombo: KeyCombo? = CaptureHotkeyDefaults.load()
    @State private var videoCaptureHotkeyCombo: KeyCombo? = VideoCaptureHotkeyDefaults.load()
    @State private var retentionDays = RetentionDefaults.loadRetentionDays()
    @State private var maxItemCount = RetentionDefaults.loadMaxItemCount()
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var licenseKeyInput: String = ""
    @State private var licenseErrorMessage: String?
    @State private var licenseSuccessVisible: Bool = false
    @State private var daemonStatus: DaemonStatus = .notRegistered
    @State private var isUninstalling = false

    public init() {}

    public var body: some View {
        Form {
            Section("General") {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    HotkeyRecorderView(keyCombo: $hotkeyCombo, accessibilityLabelText: "Global Hotkey")
                        .frame(width: 160, height: 24)
                }

                HStack {
                    Text("Capture GIF Hotkey")
                    Spacer()
                    HotkeyRecorderView(keyCombo: $captureHotkeyCombo, saveAction: CaptureHotkeyDefaults.save, accessibilityLabelText: "Capture GIF Hotkey")
                        .frame(width: 160, height: 24)
                }

                HStack {
                    Text("Capture Video Hotkey")
                    Spacer()
                    HotkeyRecorderView(keyCombo: $videoCaptureHotkeyCombo, saveAction: VideoCaptureHotkeyDefaults.save, accessibilityLabelText: "Capture Video Hotkey")
                        .frame(width: 160, height: 24)
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        let agent = MainAppLaunchAgentControl()
                        do {
                            if newValue {
                                try agent.register()
                            } else {
                                try agent.unregister()
                            }
                        } catch {
                            launchAtLogin = agent.isEnabled
                        }
                    }

                HStack {
                    Text("Setup & Permissions")
                    Spacer()
                    Text("Open")
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .openOnboardingRequested, object: nil)
                }
                // One activatable element — .ignore on the inner Texts so VoiceOver
                // reads a single label and the row-level tap is the activation target.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Setup and permissions, Open")
                .accessibilityAddTraits(.isButton)
            }

            Section("Closed Lid Mode") {
                HStack {
                    Text("Helper status")
                    Spacer()
                    Text(daemonStatusText)
                        .foregroundStyle(daemonStatusColor)
                        .accessibilityLabel("Closed Lid helper status: \(daemonStatusText)")
                }
                daemonActionRow
                Text("Closed Lid keeps your Mac awake with the lid shut. It needs a one-time approval of Drobu's helper in System Settings → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Storage & Retention") {
                HStack(spacing: 8) {
                    Text("Keep items for")
                    Spacer()
                    TextField("", value: $retentionDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .accessibilityLabel("Retention days")
                        .onChange(of: retentionDays) { _, newValue in
                            let clamped = max(1, min(365, newValue))
                            if clamped != newValue {
                                retentionDays = clamped
                            }
                            RetentionDefaults.save(retentionDays: retentionDays, maxItemCount: maxItemCount)
                        }
                    Text("days")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                HStack(spacing: 8) {
                    Text("Maximum items")
                    Spacer()
                    TextField("", value: $maxItemCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .accessibilityLabel("Maximum items")
                        .onChange(of: maxItemCount) { _, newValue in
                            let clamped = max(100, min(50000, newValue))
                            if clamped != newValue {
                                maxItemCount = clamped
                            }
                            RetentionDefaults.save(retentionDays: retentionDays, maxItemCount: maxItemCount)
                        }
                    Text("items")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Text("Items older than the retention period or beyond the maximum count will be automatically deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Delete all data")
                    Spacer()
                    Text("Delete")
                        .foregroundStyle(.red)
                        .onTapGesture {
                            confirmAndDeleteAll()
                        }
                        .accessibilityLabel("Delete all clipboard history")
                        .accessibilityAddTraits(.isButton)
                }
            }

            Section("License") {
                licenseStatusRow

                if !isActivated {
                    HStack {
                        Text("Buy Drobu — $14.99")
                            .foregroundStyle(Color.accentColor)
                            .onTapGesture {
                                NSWorkspace.shared.open(PurchaseLinks.buy)
                            }
                            .accessibilityLabel("Buy Drobu for $14.99")
                            .accessibilityAddTraits(.isButton)
                        Spacer()
                    }
                    licenseKeyRow
                } else {
                    HStack {
                        Text("Deactivate license")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .onTapGesture {
                                licenseManager.deactivate()
                                licenseKeyInput = ""
                                licenseErrorMessage = nil
                            }
                            .accessibilityLabel("Deactivate license")
                            .accessibilityAddTraits(.isButton)
                        Spacer()
                    }
                }
            }

            Section("About") {
                Text("Drobu v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .foregroundStyle(.secondary)
            }

            Section("Uninstall") {
                HStack {
                    Text("Uninstall Drobu…")
                        .foregroundStyle(.red)
                    Spacer()
                }
                // Whole-row tap target; one VoiceOver element with an explicit
                // label + hint + button trait (children: .ignore avoids
                // unpredictable concatenation), mirroring daemonActionLabel.
                .contentShape(Rectangle())
                .onTapGesture { confirmAndUninstall() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Uninstall Drobu")
                .accessibilityHint("Removes the background helper and login item, then moves Drobu to the Trash. Your license stays saved. A confirmation appears first.")
                .accessibilityAddTraits(.isButton)

                Text("Removes Drobu's helper and login item — which dragging to the Trash cannot — then moves the app to the Trash. Your clipboard history and license are kept unless you choose to delete them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = MainAppLaunchAgentControl().isEnabled
            retentionDays = RetentionDefaults.loadRetentionDays()
            maxItemCount = RetentionDefaults.loadMaxItemCount()
            refreshDaemonStatus()
        }
        // Re-read daemon status when the app regains focus — picks up an
        // approval the user just toggled in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDaemonStatus()
        }
    }

    // MARK: - Closed Lid helper section

    private func refreshDaemonStatus() {
        daemonStatus = DaemonRegistrar().status
    }

    private var daemonStatusText: String {
        switch daemonStatus {
        case .enabled: return "Approved ✓"
        case .requiresApproval: return "Needs approval"
        case .notRegistered: return "Not enabled"
        case .notFound: return "Unavailable"
        case .failed: return "Error"
        }
    }

    private var daemonStatusColor: Color {
        switch daemonStatus {
        case .enabled: return .green
        case .requiresApproval, .notFound, .failed: return .red
        case .notRegistered: return .gray
        }
    }

    @ViewBuilder
    private var daemonActionRow: some View {
        switch daemonStatus {
        case .notRegistered, .notFound:
            // .notFound is the never-registered state on macOS 14+, so it must
            // register (via remediate) — not dead-end into Login Items where no
            // toggle exists yet. Mirrors DaemonRegistrar.remediate / ClosedLidService.
            daemonActionLabel("Enable Closed Lid Helper", color: .accentColor,
                              accessibility: "Enable Closed Lid helper") {
                daemonStatus = DaemonRegistrar().remediate()
            }
        case .requiresApproval:
            daemonActionLabel("Approve in System Settings", color: .accentColor,
                              accessibility: "Approve Closed Lid helper in System Settings") {
                DaemonRegistrar().openApprovalSettings()
            }
        case .enabled:
            daemonActionLabel("Remove Helper", color: .red,
                              accessibility: "Remove Closed Lid helper") {
                daemonStatus = DaemonRegistrar().unregister()
            }
        case .failed:
            daemonActionLabel("Retry", color: .accentColor,
                              accessibility: "Retry enabling Closed Lid helper") {
                daemonStatus = DaemonRegistrar().remediate()
            }
        }
    }

    private func daemonActionLabel(_ title: String, color: Color, accessibility: String,
                                   action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(color)
            Spacer()
        }
        // Whole-row tap target; one VoiceOver element with an explicit label +
        // button trait (children: .ignore avoids unpredictable concatenation).
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - License section helpers

    private var isActivated: Bool {
        if case .activated = licenseManager.status { return true }
        return false
    }

    @ViewBuilder
    private var licenseStatusRow: some View {
        switch licenseManager.status {
        case .trialActive(let daysRemaining):
            HStack {
                Text("Free trial")
                Spacer()
                Text("\(daysRemaining) day\(daysRemaining == 1 ? "" : "s") remaining")
                    .foregroundStyle(.secondary)
            }
        case .trialExpired:
            HStack {
                Text("Free trial")
                Spacer()
                Text("Expired")
                    .foregroundStyle(.red)
            }
        case .activated:
            HStack {
                Text("Status")
                Spacer()
                Text("Activated ✓")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var licenseKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Multi-line input so the full ~110-char key is visible —
            // single-line truncates and the user can't tell if the
            // paste was complete.
            // Empty title + prompt + labelsHidden so the grouped Form does
            // NOT treat this as LabeledContent (label-left / value-right),
            // which hard right-aligns the value column. With no label the
            // field spans the full row width and the pasted ~110-char key
            // reads left-aligned and monospaced, matching the license email.
            // (.multilineTextAlignment alone does not beat the grouped Form.)
            TextField("", text: $licenseKeyInput, prompt: Text("Paste license key (DROBU-…)"), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.leading)
                // Grow to fit the full key so the DROBU- prefix stays
                // visible — a fixed 3-line cap scrolled it out of view and
                // read as "I pasted something wrong".
                .lineLimit(3...6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: licenseKeyInput) { _, newValue in handleLicenseInput(newValue) }

            if licenseSuccessVisible {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Activated — welcome to Drobu")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            } else if let licenseErrorMessage {
                Text(licenseErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Paste from clipboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { pasteFromClipboard() }
                    .accessibilityLabel("Paste license key from clipboard and activate")
                    .accessibilityAddTraits(.isButton)
                Spacer()
                Text("Activate")
                    .font(.caption)
                    .foregroundStyle(licenseKeyInput.isEmpty ? Color.secondary : Color.accentColor)
                    .onTapGesture {
                        guard !licenseKeyInput.isEmpty else { return }
                        tryActivate()
                    }
                    .accessibilityLabel("Activate license key")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // A license key contains no whitespace, so any spaces/newlines are paste
    // artifacts (email line-wrapping) or a Return press in this multiline
    // field — strip them all, then auto-activate the moment a full-shaped key
    // is present. This makes "paste" the whole interaction: no Enter to find
    // (axis:.vertical TextFields never fire onSubmit on Return anyway), no
    // button to hunt for. The Activate button stays as an explicit fallback.
    // Read the key straight off the clipboard — the focus-proof path for
    // pasting into our OWN window. Drobu's clipboard panel pastes via a
    // simulated Cmd+V aimed at the previously-focused field, which macOS does
    // not reliably restore for a same-app paste (it works for external apps,
    // which keep focus while Drobu runs as an accessory). Reading the
    // pasteboard here works regardless of how the key was copied — from the
    // email, or via the Drobu panel (which also writes it to the pasteboard).
    private func pasteFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        licenseKeyInput = s   // handleLicenseInput strips whitespace + auto-activates
    }

    private func handleLicenseInput(_ newValue: String) {
        licenseErrorMessage = nil
        let cleaned = newValue.filter { !$0.isWhitespace }
        if cleaned != newValue {
            licenseKeyInput = cleaned   // re-triggers onChange; that pass activates
            return
        }
        if cleaned.hasPrefix("DROBU-"), cleaned.dropFirst(6).contains("."), cleaned.count >= 100 {
            tryActivate()
        }
    }

    private func tryActivate() {
        let cleaned = licenseKeyInput.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return }
        do {
            try licenseManager.activate(keyString: cleaned)
            licenseKeyInput = ""
            licenseErrorMessage = nil
            // Inline success confirmation. The Section re-renders to the
            // "Activated" variant automatically because licenseManager.status
            // changed, but we hold the success message for a beat so the
            // user sees what just happened.
            licenseSuccessVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                licenseSuccessVisible = false
            }
        } catch let error as LicenseError {
            switch error {
            case .malformed:
                licenseErrorMessage = "That doesn't look like a valid license key."
            case .badSignature:
                licenseErrorMessage = "License key rejected. Contact support if you need help."
            case .publicKeyMissing:
                licenseErrorMessage = "Drobu is misconfigured — contact support."
            }
        } catch {
            licenseErrorMessage = "Activation failed: \(error.localizedDescription)"
        }
    }

    private func confirmAndDeleteAll() {
        guard let window = NSApp.keyWindow else { return }

        let alert = NSAlert()
        alert.messageText = "Delete All Clipboard History?"
        alert.informativeText = "This will permanently delete all saved clipboard items. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try AppDatabase().deleteAll()
                // Also purge video files on disk
                try? FileManager.default.removeItem(at: ClipboardRecord.videosDirectory)
            } catch {
                Log.error("SettingsView: delete all data failed: \(error)")
            }
        }
    }

    // MARK: - Uninstall

    private func confirmAndUninstall() {
        guard !isUninstalling else { return }
        guard let window = NSApp.keyWindow else {
            Log.error("SettingsView: Uninstall tapped but no key window — cannot present confirmation")
            return
        }
        isUninstalling = true

        let alert = NSAlert()
        alert.messageText = "Uninstall Drobu?"
        alert.informativeText = "This removes Drobu's background helper and its launch-at-login entry, then moves the app to the Trash. Your license and trial status stay saved on this Mac, so reinstalling keeps you activated. Your clipboard history is kept unless you check the box below."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let checkbox = NSButton(checkboxWithTitle: "Also delete my clipboard history and settings",
                                target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { isUninstalling = false; return }
            let deleteData = checkbox.state == .on
            Task { @MainActor in
                let service = UninstallService()
                let result = await service.run(options: UninstallOptions(deleteData: deleteData))
                if let summary = result.residualSummary {
                    presentUninstallResidual(summary) { service.scheduleSelfDeleteAndQuit() }
                } else {
                    service.scheduleSelfDeleteAndQuit()
                }
            }
        }
    }

    /// A registration step failed — tell the user residue may remain before the
    /// app quits, then proceed with the self-delete (the app still quits; recovery
    /// is in System Settings, not a retry).
    private func presentUninstallResidual(_ summary: String, then proceed: @escaping () -> Void) {
        guard let window = NSApp.keyWindow else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "Drobu was removed"
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in proceed() }
    }
}
