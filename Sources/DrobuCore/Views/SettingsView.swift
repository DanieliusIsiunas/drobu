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
    /// Removes the privileged Closed-Lid helper via the owning `ClosedLidService`
    /// (AppDelegate). Returns false when an active session's reversal couldn't be
    /// confirmed — the helper is kept. Injected like `windowProvider` so the view
    /// never reaches the service or the daemon directly.
    var onRemoveClosedLidHelper: @MainActor () async -> Bool
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
    // Gates the About → Danger Zone "Remove Closed-Lid Helper" row (shown only
    // while the helper is registered). Refreshed on appear + app re-activation.
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
         onRemoveClosedLidHelper: @escaping @MainActor () async -> Bool,
         onFinish: @escaping () -> Void) {
        self.nav = nav
        self.onboardingModel = onboardingModel
        self.firstRun = firstRun
        self.windowProvider = windowProvider
        self.onPermissionAction = onPermissionAction
        self.onRemoveClosedLidHelper = onRemoveClosedLidHelper
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
        // Re-read daemon status when the app regains focus — picks up a Login Items
        // change made in System Settings (gates the About "Remove Closed-Lid Helper" row).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDaemonStatus()
        }
    }

    /// Keyboard navigation for the sidebar — mirrors the clipboard panel's arrow
    /// handling (`PanelView.handleClipboardKeyPress`). Match on `press.key`, never
    /// `modifiers.isEmpty`: arrow keys carry `.numericPad` on macOS.
    private func handleSidebarKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Yield while an in-pane AppKit control is actively taking the keyboard. The
        // root's .onKeyPress can otherwise intercept keys — including Esc — before they
        // reach an AppKit first responder that doesn't participate in @FocusState: a
        // text-field editor, or the hotkey recorder *while recording* (where Esc is its
        // cancel path). The recorder keeps first responder after recording ends without
        // resigning, so gate on `isRecording` — otherwise sidebar nav stays dead until
        // the user clicks a row. (A focused SwiftUI TextField already consumes its own
        // keys; this covers the AppKit responders that don't.)
        if let responder = windowProvider()?.firstResponder,
           responder is NSText || (responder as? HotkeyRecorderNSView)?.isRecording == true {
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

    // MARK: - Shared row grammar

    /// The settings row used across every pane: a leading label (with an optional
    /// secondary description) on the left, the action or control on the right.
    /// Defining it once is what keeps the panes aligned — the leading column is
    /// always plain, non-padded `Text`, so a label never inherits the `+7pt`
    /// `hoverHighlight()` padding that used to indent inline actions out of line.
    /// `verticalAlignment` defaults to `.firstTextBaseline` (text actions align
    /// with the label's first line, not a wrapped description); pass `.center` for
    /// bordered trailing controls like a hotkey recorder or text field.
    @ViewBuilder
    private func settingsRow<Trailing: View>(
        _ label: String,
        description: String? = nil,
        verticalAlignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: verticalAlignment) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    /// Inline action for a `settingsRow` trailing slot, rendered as an always-on
    /// tinted **pill** (v1.9.5 polish): `.neutral` calm-grey for safe actions,
    /// `.destructive` red — red is reserved for Delete/Uninstall and nothing else.
    /// The tinted capsule carries its own contrast, so the action stays legible on
    /// any wallpaper (the panel is translucent). Bundles the VoiceOver traits so
    /// every action reads as a button without each call site re-deriving them;
    /// append `.accessibilityHint(_:)` at the call site where one is needed.
    private func actionLink(
        _ title: String,
        destructive: Bool = false,
        a11yLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Text(title)
            .actionPill(destructive ? .destructive : .neutral)
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
            .accessibilityAddTraits(.isButton)
    }

    /// Non-interactive status chip for `licenseStatusRow` — the same pill shape as
    /// the actions but no hover/tap. `dot` adds a leading filled circle (used for
    /// the positive "Activated" state).
    private func statusPill(_ text: String, role: SettingsPillRole, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(role.foreground).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(role.foreground)
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(Capsule().fill(role.fill(hovering: false)))
    }

    // MARK: - Set Up pane (embeds the onboarding checklist)

    @ViewBuilder
    private var setUpPane: some View {
        let presentation: OnboardingView.Presentation =
            showsWelcomeChrome(in: .setUp, firstRun: firstRun) ? .onboarding : .settingsSection
        // The closed-lid teardown used to live here as an orphaned bottom-of-pane
        // button; it now belongs to the "Closed-lid keep-awake" row itself (a
        // trailing "Remove" action in OnboardingView), so this is just the checklist.
        OnboardingView(model: onboardingModel,
                       presentation: presentation,
                       onAction: onPermissionAction,
                       onFinish: onFinish)
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
        Divider()
        // Static reference (not a shortcutRow): the ⌘→ edit key is an in-panel,
        // context-dependent shortcut, not a rebindable global hotkey. Chrome-free (no
        // field box) and greyed to .tertiary so it clearly reads as a reference, not an
        // editable control; the 160x24 footprint keeps it aligned with the rows above.
        settingsRow("Edit Mode", verticalAlignment: .center) {
            Text("\u{2318}\u{2192}")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 160, height: 24)
                .accessibilityLabel("Command Right arrow")
        }
    }

    private func shortcutRow(_ label: String, binding: Binding<KeyCombo?>,
                             save: @escaping @MainActor (KeyCombo?) -> Void, a11y: String) -> some View {
        // `.center` keeps the bordered recorder vertically aligned with the label
        // (the row's text-baseline default suits text actions, not controls).
        settingsRow(label, verticalAlignment: .center) {
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

        Divider()
        settingsRow("Delete all data") {
            actionLink("Delete", destructive: true,
                       a11yLabel: "Delete all clipboard history") { confirmAndDeleteAll() }
        }
    }

    // MARK: - License pane

    @ViewBuilder
    private var licensePane: some View {
        paneTitle("License")
        licenseStatusRow

        if !isActivated {
            Divider()
            HStack {
                Text("Buy Drobu — $14.99")
                    .actionPill(.neutral)
                    .onTapGesture { NSWorkspace.shared.open(PurchaseLinks.buy) }
                    .accessibilityElement(children: .ignore)
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

            Divider()

            // Frees THIS Mac's seat on the server AND clears the local key — the
            // single deactivation action a user needs. The local-only
            // `LicenseManager.deactivate()` has deliberately no UI: it leaves the
            // seat consumed server-side, so exposing it beside this only invited a
            // "wrong button -> stranded seat" mistake (the method stays — it is
            // called internally once the seat is freed).
            settingsRow("Deactivate this Mac",
                        description: "Frees this seat so you can use Drobu on another computer.") {
                actionLink("Deactivate",
                           a11yLabel: "Deactivate this Mac and free its license seat") {
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
        // The one Drobu-installed helper that can be removed lives here, next to
        // Uninstall — the Set Up checklist shows it as a plain status row ("Ready"),
        // like every other permission. Shown only while the helper is registered.
        if daemonStatus == .enabled || daemonStatus == .requiresApproval {
            settingsRow("Remove Closed-Lid Helper",
                        description: "Unregisters the background helper from Login Items. Closed Lid mode stops working until you re-enable it in Set Up.") {
                actionLink("Remove", destructive: true,
                           a11yLabel: "Remove Closed-Lid helper") { removeClosedLidHelper() }
            }
            Divider()
        }
        settingsRow("Uninstall Drobu…",
                    description: "Removes Drobu's helper and login item — which dragging to the Trash cannot — then moves the app to the Trash. Your clipboard history and license are kept unless you choose to delete them.") {
            actionLink("Uninstall…", destructive: true,
                       a11yLabel: "Uninstall Drobu") { confirmAndUninstall() }
                // The visible row description (read aloud by VoiceOver) already
                // covers what is removed/kept, so the hint adds only the one thing
                // it doesn't say — avoids speaking the same content twice.
                .accessibilityHint("A confirmation appears first.")
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func refreshDaemonStatus() {
        daemonStatus = DaemonRegistrar().status
    }

    /// Remove the privileged Closed-Lid helper. Delegated to the owning
    /// `ClosedLidService` (AppDelegate) via `onRemoveClosedLidHelper`: it reverses an
    /// active session AND tears down its own local state (menu dot, clamshell poll,
    /// caffeinate) BEFORE the registration is removed, and skips the daemon step for a
    /// `.requiresApproval` helper (registered but not running). Returns false when an
    /// active session's reversal couldn't be confirmed — the helper is kept (the only
    /// owner that can retry), so surface the manual recovery path instead.
    private func removeClosedLidHelper() {
        Task { @MainActor in
            if await onRemoveClosedLidHelper() {
                refreshDaemonStatus()
            } else {
                presentClosedLidReversalFailure()
            }
        }
    }

    /// Reversal of an active Closed-Lid session couldn't be confirmed, so the helper
    /// was kept (it retries `pmset disablesleep 0` daemon-side). Surface the manual
    /// recovery path, mirroring `UninstallService`'s failure-surfacing copy.
    private func presentClosedLidReversalFailure() {
        guard let window = windowProvider() ?? NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't confirm your Mac's sleep setting was restored"
        alert.informativeText = "The Closed-Lid helper was kept so it can finish restoring your sleep setting — try Remove again in a moment. If your Mac still won't sleep, open Terminal and run:\n\nsudo pmset -a disablesleep 0"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
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
                statusPill("Expired", role: .destructive)
            }
        case .activated:
            HStack {
                Text("Status")
                Spacer()
                statusPill("Activated", role: .success, dot: true)
            }
        case .activationLimitReached:
            HStack {
                Text("Status")
                Spacer()
                statusPill("Device limit reached", role: .warning)
            }
        case .licenseRevoked:
            HStack {
                Text("Status")
                Spacer()
                statusPill("Refunded", role: .destructive)
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
                    .actionPill(.neutral)
                    .onTapGesture { pasteFromClipboard() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Paste license key from clipboard and activate")
                    .accessibilityAddTraits(.isButton)
                Spacer()
                Text("Activate")
                    .actionPill(.neutral, enabled: !licenseKeyInput.isEmpty)
                    .onTapGesture {
                        guard !licenseKeyInput.isEmpty else { return }
                        tryActivate()
                    }
                    .accessibilityElement(children: .ignore)
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
