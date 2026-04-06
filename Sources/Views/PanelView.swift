import AVFoundation
import Carbon.HIToolbox
import CryptoKit
import SwiftUI
import GRDB

enum PanelMode: Equatable {
    case clipboard
    case commandList
    case commandOptions(commandName: String)
}

struct PanelView: View {
    let database: AppDatabase
    let commands: [any SlashCommand]

    // MARK: - Layout Constants (single source of truth)

    /// Change this to show more or fewer rows in the panel.
    static let visibleItemCount = 11

    static let panelWidth: CGFloat = 780
    static let listWidth: CGFloat = 340
    private static let rowSpacing: CGFloat = 2   // LazyVStack spacing
    private static let listPadding: CGFloat = 4  // .padding(.vertical, 4) on list container

    /// Exact height for the item list area, computed from row constants.
    static let listAreaHeight: CGFloat = {
        let rows = CGFloat(visibleItemCount) * ClipboardRowView.rowHeight
        let spacing = CGFloat(visibleItemCount - 1) * rowSpacing
        let padding = 2 * listPadding
        return rows + spacing + padding
    }()

    @State private var searchText = ""
    @State private var allItems: [ClipboardRecord] = []   // raw from DB observation
    @State private var items: [ClipboardRecord] = []      // filtered by activeFilter
    @State private var anchor = 0      // where Shift-select started
    @State private var cursor = 0      // current keyboard position
    @State private var observation: AnyDatabaseCancellable?
    @State private var isEditing = false
    @State private var editingText = ""
    @State private var originalText = ""
    @State private var editingItemId: Int64?   // track edited item across list refreshes
    @State private var panelMode: PanelMode = .clipboard
    @State private var activeSection: Int = 0
    @State private var activeFilter: Int = 0
    @State private var availableKinds: [String] = []
    @State private var largePreviewPanel: LargePreviewPanel?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.floatingPanel) private var panelWrapper

    private var panel: FloatingPanel? { panelWrapper.panel }

    private var selectionRange: ClosedRange<Int> {
        min(anchor, cursor)...max(anchor, cursor)
    }

    private var hasMultiSelection: Bool {
        anchor != cursor
    }

    private var selectedItems: [ClipboardRecord] {
        guard !items.isEmpty else { return [] }
        let clamped = selectionRange.clamped(to: 0...(items.count - 1))
        return Array(items[clamped])
    }

    private var previewItem: ClipboardRecord? {
        guard panelMode == .clipboard, cursor < items.count else { return nil }
        return items[cursor]
    }

    // MARK: - Content Type Filters

    private static let kindOrder = [ClipboardRecord.kindText, ClipboardRecord.kindImage, ClipboardRecord.kindGif, ClipboardRecord.kindVideo, ClipboardRecord.kindFile]
    private static let kindLabels: [String: String] = [
        ClipboardRecord.kindText: "Text",
        ClipboardRecord.kindImage: "Image",
        ClipboardRecord.kindGif: "GIF",
        ClipboardRecord.kindVideo: "Video",
        ClipboardRecord.kindFile: "File",
    ]

    private var availableFilters: [(label: String, kind: String?)] {
        var filters: [(label: String, kind: String?)] = [("All", nil)]
        for kind in Self.kindOrder {
            if availableKinds.contains(kind), let label = Self.kindLabels[kind] {
                filters.append((label, kind))
            }
        }
        return filters
    }

    private var activeFilterKind: String? {
        guard activeFilter < availableFilters.count else { return nil }
        return availableFilters[activeFilter].kind
    }

    // MARK: - Filtered Commands

    private var filteredCommands: [any SlashCommand] {
        let query = String(searchText.dropFirst()) // Remove leading "/"
        if query.isEmpty { return commands }
        return commands.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var selectedCommand: (any SlashCommand)? {
        if case .commandOptions(let name) = panelMode {
            return commands.first(where: { $0.name == name })
        }
        return nil
    }

    /// Options filtered to the active section (for commands with sections).
    private var activeSectionOptions: [CommandOption] {
        guard let cmd = selectedCommand else { return [] }
        let allOpts = cmd.options()
        let secs = cmd.sections
        guard !secs.isEmpty, activeSection < secs.count else { return allOpts }
        let sectionName = secs[activeSection]
        return allOpts.filter { $0.section == sectionName }
    }

    // MARK: - Item Count for Current Mode

    private var currentListCount: Int {
        switch panelMode {
        case .clipboard: return items.count
        case .commandList: return filteredCommands.count
        case .commandOptions: return activeSectionOptions.count
        }
    }

    // MARK: - Search Bar

    private var searchPlaceholder: String {
        switch panelMode {
        case .clipboard: return "Search clipboard..."
        case .commandList, .commandOptions: return "Type a command..."
        }
    }

    private var searchIcon: String {
        switch panelMode {
        case .clipboard: return "magnifyingglass"
        case .commandList, .commandOptions: return "terminal"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field (full width)
            HStack(spacing: 8) {
                Image(systemName: searchIcon)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)
                    .accessibilityLabel(panelMode == .clipboard ? "Search clipboard" : "Search commands")
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Split layout: list | preview
            if panelMode != .clipboard && currentListCount == 0 {
                commandEmptyState
                    .frame(height: Self.listAreaHeight)
            } else {
                HStack(spacing: 0) {
                    // Left panel: list
                    listContent
                        .frame(width: Self.listWidth)

                    Divider()

                    // Right panel: preview / command info
                    previewContent
                        .frame(maxWidth: .infinity)
                }
                .frame(height: Self.listAreaHeight)
            }
        }
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground())
        .onAppear {
            startObservation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
                if let buffered = panel?.consumeBufferedKeystrokes(), !buffered.isEmpty {
                    searchText = buffered
                }
            }
            panel?.onShiftTap = { [self] in
                // Always allow closing an open preview, regardless of mode
                if largePreviewPanel != nil {
                    closeLargePreview()
                    return
                }
                guard !isEditing, panelMode == .clipboard else { return }
                toggleLargePreview()
            }
        }
        .onDisappear {
            if isEditing { saveEdit() }
            closeLargePreview()
            observation?.cancel()
            observation = nil
            searchText = ""
            isEditing = false
            editingItemId = nil
            editingText = ""
            originalText = ""
            anchor = 0
            cursor = 0
            panelMode = .clipboard
            activeSection = 0
            activeFilter = 0
            allItems = []
        }
        .onChange(of: searchText) { _, newValue in
            if isEditing { discardEdit() }

            if newValue.hasPrefix("/") {
                if case .commandOptions = panelMode {
                    // Don't change mode while in options — search bar is frozen
                } else {
                    panelMode = .commandList
                    observation?.cancel()
                    observation = nil
                    cursor = 0
                    anchor = 0
                }
            } else {
                if panelMode != .clipboard { panelMode = .clipboard }
                cursor = 0
                anchor = 0
                startObservation()
            }
        }
        .onChange(of: activeFilter) { _, _ in
            if panelMode == .clipboard {
                cursor = 0
                anchor = 0
                refilterItems()
            }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in
            switch panelMode {
            case .clipboard:
                return handleClipboardKeyPress(press)
            case .commandList:
                return handleCommandListKeyPress(press)
            case .commandOptions:
                return handleCommandOptionsKeyPress(press)
            }
        }
        // Cmd+1 through Cmd+9 shortcuts (clipboard mode only)
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789"), phases: .down) { press in
            guard panelMode == .clipboard,
                  !isEditing,
                  press.modifiers == .command,
                  let char = press.characters.first,
                  let digit = Int(String(char)),
                  digit >= 1, digit <= 9 else {
                return .ignored
            }
            let index = digit - 1
            guard index < items.count else { return .ignored }
            anchor = index
            cursor = index
            panel?.pasteItem(items[index])
            return .handled
        }
    }

    // MARK: - List Content (mode-switched)

    @ViewBuilder
    private var listContent: some View {
        switch panelMode {
        case .clipboard:
            clipboardList
        case .commandList:
            commandListView
        case .commandOptions:
            commandOptionsListView
        }
    }

    // MARK: - Preview Content (mode-switched)

    @ViewBuilder
    private var previewContent: some View {
        switch panelMode {
        case .clipboard:
            PreviewPanel(
                item: previewItem,
                selectionCount: selectedItems.count,
                isEditing: $isEditing,
                editingText: $editingText,
                onSave: { saveEdit() },
                onDiscard: { discardEdit() },
                onGifSave: { trimmedData in saveGifTrim(data: trimmedData) },
                onVideoSave: { trimmedURL in saveVideoTrim(url: trimmedURL) },
                onCleanup: { cleanupText() }
            )
        case .commandList:
            commandListPreview
        case .commandOptions:
            commandOptionsPreview
        }
    }

    // MARK: - Clipboard List (existing)

    private var clipboardList: some View {
        VStack(spacing: 0) {
            filterTabs()

            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clipboard")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text(searchText.isEmpty && activeFilterKind == nil
                         ? "Copy something to get started"
                         : "No matches found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRowView(
                                    item: item,
                                    isSelected: selectionRange.contains(index),
                                    isCursor: index == cursor,
                                    shortcutIndex: index < 9 ? index : nil
                                )
                                .id(item.id)
                                .onTapGesture {
                                    anchor = index
                                    cursor = index
                                    panel?.pasteItem(items[index])
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: cursor) { _, newValue in
                        guard panelMode == .clipboard, newValue < items.count else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(items[newValue].id, anchor: .center)
                        }
                        largePreviewPanel?.update(for: items[newValue])
                    }
                }
            }

            Divider()
            Text("\u{2190}\u{2192} filter  \u{2191}\u{2193} navigate  \u{21B5} paste  \u{21E7} preview")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Filter Tabs

    @ViewBuilder
    private func filterTabs() -> some View {
        HStack(spacing: 6) {
            ForEach(Array(availableFilters.enumerated()), id: \.offset) { index, filter in
                Text(filter.label)
                    .font(.system(size: 13, weight: index == activeFilter ? .semibold : .regular))
                    .foregroundStyle(index == activeFilter ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(index == activeFilter ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                    )
                    .onTapGesture {
                        if activeFilter != index {
                            activeFilter = index
                            cursor = 0
                            anchor = 0
                        }
                    }
                    .accessibilityLabel("\(filter.label) filter")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(index == activeFilter ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Command List

    private var commandListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(filteredCommands.enumerated()), id: \.element.name) { index, command in
                        CommandItemRow(
                            label: command.displayName,
                            icon: command.icon,
                            isCursor: index == cursor
                        )
                        .id(command.name)
                        .onTapGesture {
                            selectCommand(at: index)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: cursor) { _, newValue in
                guard panelMode == .commandList else { return }
                let cmds = filteredCommands
                guard newValue < cmds.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(cmds[newValue].name, anchor: .center)
                }
            }
        }
    }

    // MARK: - Command Options List

    private var commandOptionsListView: some View {
        // TimelineView re-evaluates every 1s so the option list updates
        // when a timed command (e.g. sleep prevention) expires naturally.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 0) {
                // Section tabs (only shown for commands with sections)
                if let cmd = selectedCommand, !cmd.sections.isEmpty {
                    sectionTabs(sections: cmd.sections)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(activeSectionOptions.enumerated()), id: \.element.id) { index, option in
                                CommandItemRow(
                                    label: option.label,
                                    icon: option.icon,
                                    isCursor: index == cursor,
                                    isDestructive: option.isDestructive
                                )
                                .id(option.id)
                                .onTapGesture {
                                    executeSectionOption(at: index)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: cursor) { _, newValue in
                        guard case .commandOptions = panelMode else { return }
                        let opts = activeSectionOptions
                        guard newValue < opts.count else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(opts[newValue].id, anchor: .center)
                        }
                    }
                }

                // Footer hint for section navigation
                if let cmd = selectedCommand, !cmd.sections.isEmpty {
                    Divider()
                    Text("\u{2190}\u{2192} section  \u{2191}\u{2193} navigate  \u{21B5} select")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Section Tabs

    @ViewBuilder
    private func sectionTabs(sections: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                Text(section)
                    .font(.system(size: 13, weight: index == activeSection ? .semibold : .regular))
                    .foregroundStyle(index == activeSection ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(index == activeSection ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                    )
                    .onTapGesture {
                        if activeSection != index {
                            activeSection = index
                            cursor = 0
                            anchor = 0
                        }
                    }
                    .accessibilityLabel("\(section) section")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(index == activeSection ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Command Preview Panels

    private var commandListPreview: some View {
        VStack(spacing: 8) {
            Spacer()
            let cmds = filteredCommands
            if cursor < cmds.count {
                commandPreviewContent(for: cmds[cursor])
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.quaternary)
                Text("Select a command")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var commandOptionsPreview: some View {
        VStack(spacing: 8) {
            Spacer()
            if let cmd = selectedCommand {
                commandPreviewContent(for: cmd)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func commandPreviewContent(for cmd: any SlashCommand) -> some View {
        if cmd.isActive {
            cmd.activeStatusView()
        } else {
            Image(systemName: cmd.icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(cmd.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(cmd.description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty States

    private var commandEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("No matching commands")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Keyboard Handlers

    private func handleClipboardKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // When editing, let NSTextView handle all keys
        if isEditing { return .ignored }

        switch press.key {
        case .rightArrow:
            // Cmd+Right → enter edit mode
            if press.modifiers.contains(.command) {
                guard !items.isEmpty, !hasMultiSelection else { return .ignored }
                let item = items[cursor]
                if item.kind == ClipboardRecord.kindText, item.plainText != nil {
                    enterEditMode()
                    return .handled
                }
                if item.kind == ClipboardRecord.kindGif, item.imageData != nil {
                    enterEditMode()
                    return .handled
                }
                if item.kind == ClipboardRecord.kindVideo {
                    let url = ClipboardRecord.videoPath(for: item.contentHash)
                    if FileManager.default.fileExists(atPath: url.path) {
                        enterEditMode()
                        return .handled
                    }
                }
                return .ignored
            }
            // Plain Right → next filter tab
            if activeFilter < availableFilters.count - 1 {
                activeFilter += 1
            }
            return .handled

        case .leftArrow:
            if activeFilter > 0 {
                activeFilter -= 1
            }
            return .handled

        case .downArrow:
            guard !items.isEmpty else { return .handled }
            if press.modifiers.contains(.shift) {
                if cursor < items.count - 1 { cursor += 1 }
            } else {
                let newIndex = hasMultiSelection
                    ? min(max(anchor, cursor), items.count - 1)
                    : (cursor + 1) % items.count
                anchor = newIndex
                cursor = newIndex
            }
            return .handled

        case .upArrow:
            guard !items.isEmpty else { return .handled }
            if press.modifiers.contains(.shift) {
                if cursor > 0 { cursor -= 1 }
            } else {
                let newIndex = hasMultiSelection
                    ? min(anchor, cursor)
                    : (cursor - 1 + items.count) % items.count
                anchor = newIndex
                cursor = newIndex
            }
            return .handled

        case .return:
            pasteSelected()
            return .handled

        case .escape:
            if largePreviewPanel != nil {
                closeLargePreview()
            } else if hasMultiSelection {
                anchor = cursor
            } else if !searchText.isEmpty {
                searchText = ""
            } else {
                panel?.close()
            }
            return .handled

        case .deleteForward:
            deleteSelected()
            return .handled

        default:
            return .ignored
        }
    }

    private func handleCommandKeyPress(_ press: KeyPress, count: Int, onReturn: () -> Void, onEscape: () -> Void) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            guard count > 0 else { return .handled }
            cursor = (cursor + 1) % count
            anchor = cursor
            return .handled

        case .upArrow:
            guard count > 0 else { return .handled }
            cursor = (cursor - 1 + count) % count
            anchor = cursor
            return .handled

        case .return:
            onReturn()
            return .handled

        case .escape:
            onEscape()
            return .handled

        case .rightArrow, .deleteForward:
            return .handled

        default:
            return .ignored
        }
    }

    private func handleCommandListKeyPress(_ press: KeyPress) -> KeyPress.Result {
        handleCommandKeyPress(
            press,
            count: filteredCommands.count,
            onReturn: { selectCommand(at: cursor) },
            onEscape: { searchText = "" }
        )
    }

    private func handleCommandOptionsKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Backspace acts as Escape in command options
        if press.key == .delete {
            returnToCommandList()
            return .handled
        }

        // Left/right arrows switch sections
        if let cmd = selectedCommand, !cmd.sections.isEmpty {
            if press.key == .leftArrow {
                if activeSection > 0 {
                    activeSection -= 1
                    cursor = 0
                    anchor = 0
                }
                return .handled
            }
            if press.key == .rightArrow {
                if activeSection < cmd.sections.count - 1 {
                    activeSection += 1
                    cursor = 0
                    anchor = 0
                }
                return .handled
            }
        }

        return handleCommandKeyPress(
            press,
            count: activeSectionOptions.count,
            onReturn: { executeSectionOption(at: cursor) },
            onEscape: { returnToCommandList() }
        )
    }

    private func returnToCommandList() {
        panelMode = .commandList
        searchText = "/"
        cursor = 0
        anchor = 0
        activeSection = 0
    }

    // MARK: - Command Actions

    private func selectCommand(at index: Int) {
        let cmds = filteredCommands
        guard index < cmds.count else { return }
        let cmd = cmds[index]

        // Auto-execute commands that have exactly one option
        let opts = cmd.options()
        if opts.count == 1 {
            Task {
                if let opt = opts.first { await cmd.execute(option: opt) }
                panel?.close()
            }
            return
        }

        panelMode = .commandOptions(commandName: cmd.name)
        searchText = "/\(cmd.name)"
        cursor = 0
        anchor = 0

        // Default to the active mode's section if one is active
        if let sleepCmd = cmd as? SleepCommand, !sleepCmd.sections.isEmpty {
            if let activeName = sleepCmd.activeSectionName,
               let idx = sleepCmd.sections.firstIndex(of: activeName) {
                activeSection = idx
            } else {
                activeSection = 0
            }
        } else {
            activeSection = 0
        }
    }

    /// Execute an option from the section-filtered list.
    private func executeSectionOption(at index: Int) {
        let opts = activeSectionOptions
        guard index < opts.count else { return }
        guard let cmd = selectedCommand else { return }
        let option = opts[index]
        Task {
            await cmd.execute(option: option)
            panel?.close()
        }
    }

    // MARK: - Database Observation

    private func startObservation() {
        observation?.cancel()
        let query = searchText
        let pool = database.pool

        observation = ValueObservation.tracking { db in
            let kinds = try ClipboardRecord.availableKinds(in: db)
            let items = try ClipboardRecord.search(query: query, in: db)
            return (kinds, items)
        }
        .start(in: pool, onError: { error in
            Log.error("PanelView: observation failed: \(error)")
        }, onChange: { [self] result in
            let (newKinds, newItems) = result
            availableKinds = newKinds
            allItems = newItems

            // Auto-reset filter if the active kind no longer exists
            if let kind = activeFilterKind, !newKinds.contains(kind) {
                activeFilter = 0
            }

            refilterItems()

            // While editing, follow the edited item to its new index
            if isEditing, let targetId = editingItemId,
               let newIndex = items.firstIndex(where: { $0.id == targetId }) {
                anchor = newIndex
                cursor = newIndex
            }
        })
    }

    /// Derive `items` from `allItems` by applying the active content-type filter.
    private func refilterItems() {
        if let kind = activeFilterKind {
            items = allItems.filter { $0.kind == kind }
        } else {
            items = allItems
        }
        let maxIdx = max(0, items.count - 1)
        if anchor > maxIdx { anchor = maxIdx }
        if cursor > maxIdx { cursor = maxIdx }

        // Update or close large preview after items change
        if items.isEmpty {
            closeLargePreview()
        } else if cursor < items.count {
            largePreviewPanel?.update(for: items[cursor])
        }
    }

    // MARK: - Large Preview

    private func toggleLargePreview() {
        if largePreviewPanel != nil {
            closeLargePreview()
        } else {
            guard let item = previewItem, let parentPanel = panel else { return }
            guard let screen = parentPanel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
            let preview = LargePreviewPanel()
            preview.onNavigationKey = { keyCode in
                self.handleLargePreviewKey(keyCode)
            }
            preview.show(for: item, on: screen)
            parentPanel.addChildWindow(preview, ordered: .above)
            largePreviewPanel = preview
        }
    }

    private func handleLargePreviewKey(_ keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_Escape:
            closeLargePreview()
        case kVK_UpArrow:
            guard !items.isEmpty else { return }
            let newIndex = (cursor - 1 + items.count) % items.count
            anchor = newIndex
            cursor = newIndex
        case kVK_DownArrow:
            guard !items.isEmpty else { return }
            let newIndex = (cursor + 1) % items.count
            anchor = newIndex
            cursor = newIndex
        case kVK_LeftArrow:
            if activeFilter > 0 { activeFilter -= 1 }
        case kVK_RightArrow:
            if activeFilter < availableFilters.count - 1 { activeFilter += 1 }
        case kVK_Return:
            pasteSelected()
        case kVK_ForwardDelete:
            deleteSelected()
        default:
            break
        }
    }

    private func closeLargePreview() {
        largePreviewPanel?.close()
        largePreviewPanel = nil
    }

    // MARK: - Edit Mode

    private func enterEditMode() {
        let item = items[cursor]
        editingText = item.plainText ?? ""
        originalText = editingText
        editingItemId = item.id
        isEditing = true
    }

    private func cleanupText() {
        let cleaned = TerminalTextCleaner.clean(editingText)
        guard !cleaned.isEmpty, cleaned != editingText else { return }
        editingText = cleaned
    }

    private func saveEdit() {
        guard isEditing else { return }

        // For GIF items, save is handled by saveGifTrim (called from onGifSave)
        if let item = items.first(where: { $0.id == editingItemId }),
           item.kind == ClipboardRecord.kindGif {
            discardEdit()
            return
        }

        isEditing = false
        let savedItemId = editingItemId
        editingItemId = nil
        isSearchFocused = true

        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip save if unchanged
        guard trimmed != originalText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        // Reject empty text
        guard !trimmed.isEmpty else { return }

        guard let itemId = savedItemId else { return }

        Task.detached {
            do {
                try await database.pool.write { db in
                    try ClipboardRecord.updatePlainText(id: itemId, newText: trimmed, in: db)
                }
            } catch {
                Log.error("PanelView: saveEdit failed: \(error)")
            }
        }

        // Item moves to top when ValueObservation fires
        anchor = 0
        cursor = 0
    }

    private func saveGifTrim(data: Data) {
        guard isEditing else { return }
        isEditing = false
        let savedItemId = editingItemId
        editingItemId = nil
        isSearchFocused = true

        guard let itemId = savedItemId else { return }

        Task.detached {
            do {
                try await database.pool.write { db in
                    try ClipboardRecord.updateGifData(id: itemId, newData: data, in: db)
                }
            } catch {
                Log.error("PanelView: saveGifTrim failed: \(error)")
            }
        }

        // Item moves to top when ValueObservation fires
        anchor = 0
        cursor = 0
    }

    private func saveVideoTrim(url trimmedURL: URL) {
        guard isEditing else { return }
        isEditing = false
        let savedItemId = editingItemId
        editingItemId = nil
        isSearchFocused = true

        guard let itemId = savedItemId else { return }

        Task.detached {
            // Compute hash first (needed for cleanup on error)
            guard let fileHandle = try? FileHandle(forReadingFrom: trimmedURL) else {
                Log.error("PanelView: video trim — failed to read trimmed file")
                do { try FileManager.default.removeItem(at: trimmedURL) }
                catch { Log.debug("PanelView: cleanup trimmed file failed: \(error)") }
                return
            }
            var hasher = CryptoKit.SHA256()
            while true {
                let chunk = fileHandle.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            do { try fileHandle.close() }
            catch { Log.debug("PanelView: close file handle failed: \(error)") }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let finalURL = ClipboardRecord.videoPath(for: hash)

            do {
                // 1. Move trimmed file to videos directory
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: trimmedURL, to: finalURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)

                // 3. Extract new thumbnail at 0.5s
                let thumbnail: Data? = {
                    let asset = AVAsset(url: finalURL)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                    let time = CMTime(seconds: 0.5, preferredTimescale: 600)
                    guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                    return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                }()

                // 4. Get trimmed duration
                let asset = AVAsset(url: finalURL)
                let duration = try await asset.load(.duration).seconds
                let minutes = Int(duration) / 60
                let seconds = Int(duration) % 60
                let formatted = String(format: "%d:%02d", minutes, seconds)

                // 5. Update DB: crash-safe ordering (write file → update DB → delete old)
                let oldHash: String? = try await database.pool.write { db in
                    let oldHash: String? = try String.fetchOne(db, sql: "SELECT contentHash FROM clipboardItem WHERE id = ?", arguments: [itemId])

                    try db.execute(
                        sql: "DELETE FROM clipboardItem WHERE contentHash = ? AND id != ?",
                        arguments: [hash, itemId]
                    )

                    try db.execute(
                        sql: """
                            UPDATE clipboardItem
                            SET contentHash = ?, imageData = ?, plainText = ?, createdAt = ?
                            WHERE id = ?
                            """,
                        arguments: [hash, thumbnail, "Screen Recording (\(formatted))", Date(), itemId]
                    )

                    return oldHash
                }

                // Delete old video file AFTER DB transaction commits
                if let oldHash, oldHash != hash {
                    do { try FileManager.default.removeItem(at: ClipboardRecord.videoPath(for: oldHash)) }
                    catch { Log.debug("PanelView: cleanup old video failed: \(error)") }
                }
            } catch {
                Log.error("PanelView: saveVideoTrim failed: \(error)")
                // Clean up: try both paths. One will exist depending on where the error occurred.
                do { try FileManager.default.removeItem(at: trimmedURL) }
                catch { Log.debug("PanelView: cleanup trimmedURL failed: \(error)") }
                do { try FileManager.default.removeItem(at: finalURL) }
                catch { Log.debug("PanelView: cleanup finalURL failed: \(error)") }
            }
        }

        anchor = 0
        cursor = 0
    }

    private func discardEdit() {
        isEditing = false
        editingItemId = nil
        editingText = originalText
        isSearchFocused = true
    }

    // MARK: - Actions

    private func pasteSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        if selected.count == 1 {
            if let first = selected.first { panel?.pasteItem(first) }
        } else {
            panel?.pasteItems(selected)
        }
    }

    private func deleteSelected() {
        let selected = selectedItems
        let toDelete = selected.compactMap(\.id)
        guard !toDelete.isEmpty else { return }

        // Collect video hashes before deletion (needed to find files on disk)
        let videoHashes = selected
            .filter { $0.kind == ClipboardRecord.kindVideo }
            .map(\.contentHash)

        let afterIndex = max(anchor, cursor) + 1
        let newIndex = afterIndex < items.count
            ? afterIndex - toDelete.count
            : max(0, min(anchor, cursor) - 1)

        Task.detached {
            do {
                try await database.pool.write { db in
                    for id in toDelete {
                        try ClipboardRecord.deleteById(id, in: db)
                    }
                }
                // Delete video files only after DB delete succeeds
                for hash in videoHashes {
                    do { try FileManager.default.removeItem(at: ClipboardRecord.videoPath(for: hash)) }
                    catch { Log.debug("PanelView: cleanup video \(hash.prefix(8)) failed: \(error)") }
                }
            } catch {
                Log.error("PanelView: deleteSelected failed: \(error)")
            }
        }

        let safeIndex = max(0, min(newIndex, items.count - toDelete.count - 1))
        anchor = safeIndex
        cursor = safeIndex
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
