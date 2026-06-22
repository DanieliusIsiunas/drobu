import SwiftUI
import HotKey
import Combine

/// The unified Settings panel content: a sidebar of sections + a detail pane.
/// Hosted by `SettingsPanel` (an AppDelegate-owned floating `NSPanel`). The
/// "Set Up" section embeds `OnboardingView` (first-run welcome + CTA, or a plain
/// revisitable permission list); the other sections migrate the former Settings
/// rows. Section/landing/chrome logic lives in `SettingsNavigationModel` (tested).
public struct SettingsView: View {
    // nav + onboardingModel are owned by SettingsPanel and injected into this
    // NSHostingView root — @ObservedObject is correct here (NOT @StateObject):
    // the view never owns their lifecycle, and the panel is recreated rather than
    // re-rendered by a SwiftUI parent, so @ObservedObject re-subscription is fine.
    @ObservedObject var nav: SettingsNavigationModel
    @ObservedObject var onboardingModel: OnboardingViewModel
    let firstRun: Bool
    /// Host window for destructive-confirmation sheets — resolves to the Settings
    /// window directly rather than NSApp.keyWindow (which can be nil or a
    /// different window if focus moved before the user taps Delete/Uninstall).
    var windowProvider: () -> NSWindow?
    var onPermissionAction: (OnboardingAction) -> Void
    var onFinish: () -> Void

    // Shortcuts
    @State private var hotkeyCombo: KeyCombo? = HotkeyDefaults.load()
    @State private var captureHotkeyCombo: KeyCombo? = CaptureHotkeyDefaults.load()
    @State private var videoCaptureHotkeyCombo: KeyCombo? = VideoCaptureHotkeyDefaults.load()
    // History
    @State private var retentionDays = RetentionDefaults.loadRetentionDays()
    @State private var maxItemCount = RetentionDefaults.loadMaxItemCount()
    // License
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var licenseKeyInput: String = ""
    @State private var licenseErrorMessage: String?
    @State private var licenseSuccessVisible: Bool = false
    @State private var isActivatingLicense: Bool = false
    // Closed-lid teardown (the only daemon action not covered by the Set Up
    // checklist's Enable→remediate path)
    @State private var daemonStatus: DaemonStatus = .notRegistered
    @State private var isUninstalling = false
    // Sidebar hover highlight (indicates the clickable row under the cursor).
    @State private var hoveredSection: SettingsSection?
    // Keyboard navigation: the root holds key focus so arrows/number keys drive
    // the sidebar the moment the window opens (no click needed).
    @FocusState private var keyboardNavFocused: Bool

    init(nav: SettingsNavigationModel,
         onboardingModel: OnboardingViewModel,
         firstRun: Bool,
         windowProvider: @escaping () -> NSWindow?,
         onPermissionAction: @escaping (OnboardingAction) -> Void,
         onFinish: @escaping () -> Void) {
        self.nav = nav
        self.onboardingModel = onboardingModel
        self.firstRun = firstRun
        self.windowProvider = windowProvider
        self.onPermissionAction = onPermissionAction
        self.onFinish = onFinish
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 680, height: 460)
        .background(.regularMaterial)
        // Keyboard-drive the sidebar like the rest of the app. The root holds key
        // focus by default, so arrows/number keys work the moment the window opens
        // (no click). Clicking into a text field moves focus there, so typing a
        // digit into the license field types it rather than jumping sections.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardNavFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleSidebarKeyPress(press)
        }
        .onAppear {
            retentionDays = RetentionDefaults.loadRetentionDays()
            maxItemCount = RetentionDefaults.loadMaxItemCount()
            refreshDaemonStatus()
            // Defer the focus assignment one runloop hop. A synchronous @FocusState
            // write in .onAppear can fire before the NSHostingView is installed in
            // the window's responder chain and get silently dropped (the panel is
            // recreated on each show). Mirrors PanelView's search-field focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                keyboardNavFocused = true
            }
        }
        // Re-read daemon status when the app regains focus — picks up an approval
        // the user just toggled in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDaemonStatus()
        }
    }

    /// Keyboard navigation for the sidebar — mirrors the clipboard panel's arrow
    /// handling (`PanelView.handleClipboardKeyPress`). Match on `press.key`, never
    /// `modifiers.isEmpty`: arrow keys carry `.numericPad` on macOS.
    private func handleSidebarKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Yield entirely while an in-pane AppKit control holds the keyboard. The root's
        // .onKeyPress can otherwise intercept keys — including Esc — before they reach an
        // AppKit first responder that doesn't participate in @FocusState: the hotkey
        // recorder (where Esc cancels recording) and a text-field editor. Returning
        // .ignored lets the event fall through to them instead of jumping a section or
        // closing the window. (A focused SwiftUI TextField already consumes its own keys;
        // this also covers the AppKit responders that don't.)
        if let responder = windowProvider()?.firstResponder,
           responder is NSText || responder is HotkeyRecorderNSView {
            return .ignored
        }
        switch press.key {
        case .upArrow:
            nav.selectPrevious()
            return .handled
        case .downArrow:
            nav.selectNext()
            return .handled
        case .escape:
            windowProvider()?.close()
            return .handled
        default:
            // Number keys jump straight to a section by its 1-based position. Bound
            // the range to the live section count (not a hardcoded literal) so it
            // tracks SettingsSection.allCases. Ignore digits carrying a command/
            // control/option modifier so menu shortcuts (e.g. ⌘,) pass through.
            let mods = press.modifiers
            if !mods.contains(.command), !mods.contains(.control), !mods.contains(.option),
               let number = Int(press.characters), (1...nav.sections.count).contains(number) {
                nav.select(number: number)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nav.sections) { section in
                sidebarRow(section)
            }
            Spacer()
            Text("Drobu v\(appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                .accessibilityHidden(true)   // version is read in the About pane
        }
        // Top inset clears the window's traffic-light controls (the titlebar is
        // transparent + full-size, so the trio floats over the sidebar's top).
        .padding(.top, 32)
        .frame(width: 180)
        .background(Color.primary.opacity(0.03))
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = nav.selected == section
        let isHovered = hoveredSection == section
        return HStack(spacing: 10) {
            Image(systemName: section.symbolName)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                // Selected wins; otherwise a subtle fill while hovered so the
                // clickable row is obvious before the click.
                .fill(isSelected ? Color.accentColor.opacity(0.15)
                      : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            nav.selected = section
            // Reclaim keyboard focus to the root. The .onKeyPress handler only fires
            // while the root holds key focus; after a pane control (text field /
            // hotkey recorder) takes first responder, nothing restores it and
            // arrow/number/Esc nav goes dead for the session. Clicking any section is
            // the discoverable way back — and it can't steal focus from an active
            // text field, since the click is what moved focus off it.
            keyboardNavFocused = true
        }
        .onHover { hovering in
            if hovering {
                hoveredSection = section
            } else if hoveredSection == section {
                hoveredSection = nil
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Detail router

    @ViewBuilder
    private var detail: some View {
        switch nav.selected {
        case .setUp: setUpPane
        case .shortcuts: paneScroll { shortcutsPane }
        case .history: paneScroll { historyPane }
        case .license: paneScroll { licensePane }
        case .about: paneScroll { aboutPane }
        }
    }

    /// Wraps a pane's content in a scroll view (panes are short and rarely
    /// scroll, but this prevents clipping at small heights) + a consistent title.
    @ViewBuilder
    private func paneScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, 22)
            .padding(.top, 32)   // clear the transparent full-size titlebar
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func paneTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .padding(.bottom, 2)
    }

    // MARK: - Set Up pane (embeds the onboarding checklist)

    @ViewBuilder
    private var setUpPane: some View {
        let presentation: OnboardingView.Presentation =
            showsWelcomeChrome(in: .setUp, firstRun: firstRun) ? .onboarding : .settingsSection
        VStack(spacing: 0) {
            OnboardingView(model: onboardingModel,
                           presentation: presentation,
                           onAction: onPermissionAction,
                           onFinish: onFinish)
            // Closed-lid teardown: the checklist's row covers Enable/Approve via
            // remediate and shows "Ready" once enabled, but not removal. Surface
            // "Remove Helper" here only when the helper is enabled, and only in
            // the revisitable (non-first-run) Set Up — first run is pure setup.
            if presentation == .settingsSection, daemonStatus == .enabled {
                Divider()
                HStack {
                    Text("Remove Closed-Lid Helper")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .hoverHighlight()
                        .contentShape(Rectangle())
                        .onTapGesture { daemonStatus = DaemonRegistrar().unregister() }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Remove Closed-Lid helper")
                        .accessibilityHint("Unregisters the background helper. Closed Lid mode stops working until you re-enable it.")
                        .accessibilityAddTraits(.isButton)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Shortcuts pane

    @ViewBuilder
    private var shortcutsPane: some View {
        paneTitle("Shortcuts")
        shortcutRow("Paste / open", binding: $hotkeyCombo, save: HotkeyDefaults.save, a11y: "Global Hotkey")
        Divider()
        shortcutRow("Capture GIF", binding: $captureHotkeyCombo, save: CaptureHotkeyDefaults.save, a11y: "Capture GIF Hotkey")
        Divider()
        shortcutRow("Capture video", binding: $videoCaptureHotkeyCombo, save: VideoCaptureHotkeyDefaults.save, a11y: "Capture Video Hotkey")
    }

    private func shortcutRow(_ label: String, binding: Binding<KeyCombo?>,
                             save: @escaping @MainActor (KeyCombo?) -> Void, a11y: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyRecorderView(keyCombo: binding, saveAction: save, accessibilityLabelText: a11y)
                .frame(width: 160, height: 24)
        }
    }

    // MARK: - History pane

    @ViewBuilder
    private var historyPane: some View {
        paneTitle("History")
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
                    if clamped != newValue { retentionDays = clamped }
                    RetentionDefaults.save(retentionDays: retentionDays, maxItemCount: maxItemCount)
                }
            Text("days").foregroundStyle(.secondary).fixedSize()
        }
        Divider()
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
                    if clamped != newValue { maxItemCount = clamped }
                    RetentionDefaults.save(retentionDays: retentionDays, maxItemCount: maxItemCount)
                }
            Text("items").foregroundStyle(.secondary).fixedSize()
        }
        Text("Items older than the retention period or beyond the maximum count are automatically deleted.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider().padding(.top, 6)
        HStack {
            Text("Delete all data")
            Spacer()
            Text("Delete")
                .foregroundStyle(.red)
                .hoverHighlight()
                .onTapGesture { confirmAndDeleteAll() }
                .accessibilityLabel("Delete all clipboard history")
                .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - License pane

    @ViewBuilder
    private var licensePane: some View {
        paneTitle("License")
        licenseStatusRow

        if !isActivated {
            HStack {
                Text("Buy Drobu — $14.99")
                    .foregroundStyle(Color.accentColor)
                    .hoverHighlight()
                    .onTapGesture { NSWorkspace.shared.open(PurchaseLinks.buy) }
                    .accessibilityLabel("Buy Drobu for $14.99")
                    .accessibilityAddTraits(.isButton)
                Spacer()
            }
            licenseKeyRow
        } else {
            if let email = licenseManager.licensedEmail, !email.isEmpty {
                HStack {
                    Text("Licensed to")
                    Spacer()
                    Text(email).foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Licensed to \(email)")
            }

            Text("Your license works on up to 3 Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Frees THIS Mac's seat on the server so it can be used elsewhere
            // (R3) — distinct from "Deactivate license", which only clears the
            // key locally.
            HStack {
                Text("Deactivate this Mac")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .hoverHighlight()
                    .onTapGesture {
                        Task { @MainActor in
                            let freed = await licenseManager.deactivateThisDevice()
                            if freed {
                                licenseKeyInput = ""
                                licenseErrorMessage = nil
                            } else {
                                licenseErrorMessage = "Couldn't reach the server to free this Mac's seat. Try again when you're online."
                            }
                        }
                    }
                    .accessibilityLabel("Deactivate this Mac and free its license seat")
                    .accessibilityAddTraits(.isButton)
                Spacer()
            }

            // Local-only key removal. The visible label must say it does NOT
            // free the server seat, or a user moving Macs would strand a seat
            // by clicking here instead of "Deactivate this Mac".
            VStack(alignment: .leading, spacing: 2) {
                Text("Remove key from this Mac only")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .hoverHighlight()
                    .onTapGesture {
                        licenseManager.deactivate()
                        licenseKeyInput = ""
                        licenseErrorMessage = nil
                    }
                    .accessibilityLabel("Remove the license key from this Mac only — does not free your license seat")
                    .accessibilityAddTraits(.isButton)
                Text("Keeps your seat — use \u{201C}Deactivate this Mac\u{201D} to free it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - About pane

    @ViewBuilder
    private var aboutPane: some View {
        paneTitle("About")
        Text("Drobu v\(appVersion)")
            .foregroundStyle(.secondary)
        Text("A cozy clipboard manager for macOS.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider().padding(.vertical, 8)

        // Danger zone — visually separated from the benign info above.
        Text("DANGER ZONE")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        HStack {
            Text("Uninstall Drobu…")
                .foregroundStyle(.red)
                .hoverHighlight()
                .contentShape(Rectangle())
                .onTapGesture { confirmAndUninstall() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Uninstall Drobu")
                .accessibilityHint("Removes the background helper and login item, then moves Drobu to the Trash. Your license stays saved. A confirmation appears first.")
                .accessibilityAddTraits(.isButton)
            Spacer()
        }
        Text("Removes Drobu's helper and login item — which dragging to the Trash cannot — then moves the app to the Trash. Your clipboard history and license are kept unless you choose to delete them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func refreshDaemonStatus() {
        daemonStatus = DaemonRegistrar().status
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
                Text("Expired").foregroundStyle(.red)
            }
        case .activated:
            HStack {
                Text("Status")
                Spacer()
                Text("Activated ✓").foregroundStyle(.green)
            }
        case .activationLimitReached:
            HStack {
                Text("Status")
                Spacer()
                Text("Device limit reached").foregroundStyle(.orange)
            }
        case .licenseRevoked:
            HStack {
                Text("Status")
                Spacer()
                Text("Refunded").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var licenseKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Multi-line input so the full ~110-char key is visible; empty title
            // + labelsHidden so it spans the full row width left-aligned.
            TextField("", text: $licenseKeyInput, prompt: Text("Paste license key (DROBU-…)"), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.leading)
                .lineLimit(3...6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: licenseKeyInput) { _, newValue in handleLicenseInput(newValue) }

            if licenseSuccessVisible {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Activated — welcome to Drobu").foregroundStyle(.green)
                }
                .font(.caption)
            } else if let licenseErrorMessage {
                Text(licenseErrorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text("Paste from clipboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .hoverHighlight()
                    .onTapGesture { pasteFromClipboard() }
                    .accessibilityLabel("Paste license key from clipboard and activate")
                    .accessibilityAddTraits(.isButton)
                Spacer()
                Text("Activate")
                    .font(.caption)
                    .foregroundStyle(licenseKeyInput.isEmpty ? Color.secondary : Color.accentColor)
                    .hoverHighlight()
                    .onTapGesture {
                        guard !licenseKeyInput.isEmpty else { return }
                        tryActivate()
                    }
                    .accessibilityLabel("Activate license key")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // A license key contains no whitespace, so spaces/newlines are paste
    // artifacts — strip them, then auto-activate the moment a full-shaped key is
    // present. Reads straight off the clipboard (focus-proof for pasting into our
    // own window). See the prior SettingsView for the full rationale.
    private func pasteFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        licenseKeyInput = s
    }

    private func handleLicenseInput(_ newValue: String) {
        licenseErrorMessage = nil
        let cleaned = newValue.filter { !$0.isWhitespace }
        if cleaned != newValue {
            licenseKeyInput = cleaned
            return
        }
        if cleaned.hasPrefix("DROBU-"), cleaned.dropFirst(6).contains("."), cleaned.count >= 100 {
            tryActivate()
        }
    }

    private func tryActivate() {
        let cleaned = licenseKeyInput.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, !isActivatingLicense else { return }
        isActivatingLicense = true
        Task { @MainActor in
            defer { isActivatingLicense = false }
            let verdict: ActivationVerdict?
            do {
                verdict = try await licenseManager.activate(keyString: cleaned)
            } catch let error as LicenseError {
                switch error {
                case .malformed:
                    licenseErrorMessage = "That doesn't look like a valid license key."
                case .badSignature:
                    licenseErrorMessage = "License key rejected. Contact support if you need help."
                case .publicKeyMissing:
                    licenseErrorMessage = "Drobu is misconfigured — contact support."
                }
                return
            } catch {
                licenseErrorMessage = "Activation failed: \(error.localizedDescription)"
                return
            }
            // Branch on the returned verdict, not `status` — during an unexpired
            // trial a negative verdict is persisted but `status` stays
            // .trialActive, so a status-based switch would show no feedback at all.
            switch verdict {
            case .activated, .unreachable:
                licenseKeyInput = ""
                licenseErrorMessage = nil
                licenseSuccessVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    licenseSuccessVisible = false
                }
            case .overCap(let devices):
                licenseErrorMessage = ActivationCopy.overCapMessage(deviceCount: devices.count)
            case .revoked:
                licenseErrorMessage = ActivationCopy.revokedMessage
            case nil:
                break   // superseded by a newer activation
            }
        }
    }

    // MARK: - Destructive actions (sheets anchored to the panel window)

    private func confirmAndDeleteAll() {
        guard let window = windowProvider() ?? NSApp.keyWindow else { return }
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
                try? FileManager.default.removeItem(at: ClipboardRecord.videosDirectory)
            } catch {
                Log.error("SettingsView: delete all data failed: \(error)")
            }
        }
    }

    private func confirmAndUninstall() {
        guard !isUninstalling else { return }
        guard let window = windowProvider() ?? NSApp.keyWindow else {
            Log.error("SettingsView: Uninstall tapped but no window — cannot present confirmation")
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

    private func presentUninstallResidual(_ summary: String, then proceed: @escaping () -> Void) {
        guard let window = windowProvider() ?? NSApp.keyWindow else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "Drobu was removed"
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in proceed() }
    }
}
