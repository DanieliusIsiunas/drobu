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
    /// All selection state — cherry-picked rows, the Shift-range anchor, and the
    /// keyboard cursor — lives in one pure value (`PanelSelection`, Services/), so
    /// every gesture's effect is unit-tested there rather than re-derived per call
    /// site here. Read it, never reimplement it: the grow/shrink and floor-of-one
    /// rules have pinned quirks documented on the model.
    @State private var selection = PanelSelection()
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

    /// The clipboard list's record IDs in list order — the input every
    /// `PanelSelection` operation takes (selection is keyed by ID, not index, so a
    /// new item arriving at the top can't smear the user's picks onto other rows).
    ///
    /// Index-aligned with `items` by construction: a record whose `id` is nil (not
    /// reachable for a row fetched from the DB, but the column is optional) gets a
    /// unique negative placeholder instead of being dropped, because `compactMap`
    /// would silently shift every index below it out of step with the rendered rows.
    private var itemIDs: [Int64] {
        items.enumerated().map { offset, item in item.id ?? Int64(-1 - offset) }
    }

    private var hasMultiSelection: Bool {
        selection.hasMultiSelection(ids: itemIDs)
    }

    /// The effectively selected records in list order (R4) — the paste, delete and
    /// drag payload. Sparse: a cherry-picked {0, 2, 4} yields three records.
    private var selectedItems: [ClipboardRecord] {
        guard !items.isEmpty else { return [] }
        return selection.selectedIndices(ids: itemIDs)
            .compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    private var previewItem: ClipboardRecord? {
        guard panelMode == .clipboard, selection.cursor < items.count else { return nil }
        return items[selection.cursor]
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
            selection.reset()
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
                    selection.reset()
                }
            } else {
                if panelMode != .clipboard { panelMode = .clipboard }
                selection.reset()
                startObservation()
            }
        }
        .onChange(of: activeFilter) { _, _ in
            if panelMode == .clipboard {
                selection.reset()
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
            // R9: a numeric shortcut always collapses to the one row it names, so a
            // cherry-picked set can't make ⌘3 paste something other than row 3.
            selection.collapse(to: index, ids: itemIDs)
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
                onImageSave: { croppedData in saveImageCrop(data: croppedData) },
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
                // Resolve the selection ONCE per body pass. `selectedIndices` is O(n)
                // (it scans the list for toggled IDs), so a per-row call would make
                // rendering O(n²) — the model's doc comment calls this out explicitly.
                let ids = itemIDs
                let selectedIndices = Set(selection.selectedIndices(ids: ids))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRowView(
                                    item: item,
                                    isSelected: selectedIndices.contains(index),
                                    // R13: the Return glyph is advertised only where
                                    // Return actually acts — the cursor row AND inside
                                    // the effective selection. A plain `index == cursor`
                                    // rule would keep the arrow on a row the user just
                                    // Shift+Clicked OFF, promising a paste of itself
                                    // while Return pastes the other selected rows.
                                    showsReturnAffordance: index == selection.cursor
                                        && selectedIndices.contains(index),
                                    shortcutIndex: index < 9 ? index : nil,
                                    editVerb: editVerb(forKind: item.kind)
                                )
                                .id(item.id)
                                .overlay {
                                    // AppKit drag source. The press mutates the
                                    // selection at mouseDown (Shift toggles, a plain
                                    // press outside collapses — KTD6); a
                                    // within-threshold release pastes the whole
                                    // effective selection; a drag past the threshold
                                    // drags the participants out as files.
                                    RowDragSourceView(
                                        onPress: { isShift in
                                            handleRowPress(at: index, isShift: isShift)
                                        },
                                        onTap: {
                                            pasteSelected()
                                        },
                                        dragRecords: {
                                            dragParticipants(pressedIndex: index)
                                        }
                                    )
                                }
                                // The drag overlay is accessibility-hidden, so the row
                                // itself carries the VoiceOver contract (R12). The
                                // default action (VO+Space) mirrors a plain click —
                                // same collapse-if-outside rule, then paste the
                                // effective selection — and the named action is the
                                // only way a VoiceOver user can cherry-pick at all,
                                // since Shift+Click isn't reachable from the VO cursor.
                                .accessibilityAction {
                                    handleRowPress(at: index, isShift: false)
                                    pasteSelected()
                                }
                                .accessibilityAction(named: "Toggle Selection") {
                                    handleRowPress(at: index, isShift: true)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection.cursor) { _, newValue in
                        guard panelMode == .clipboard, newValue < items.count else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(items[newValue].id, anchor: .center)
                        }
                        largePreviewPanel?.update(for: items[newValue])
                    }
                }
            }

            Divider()
            Text(clipboardFooterHint)
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
                            selection.reset()
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
                            isCursor: index == selection.cursor
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
            .onChange(of: selection.cursor) { _, newValue in
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
                                    isCursor: index == selection.cursor,
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
                    .onChange(of: selection.cursor) { _, newValue in
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
                            selection.reset()
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
            if selection.cursor < cmds.count {
                commandPreviewContent(for: cmds[selection.cursor])
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

    /// Footer hint string, with a context-sensitive `⌘→ <verb>` segment appended for the
    /// selected item when it is editable (see EditAction.swift). Decorative — the VoiceOver
    /// affordance is carried by ClipboardRowView's accessibilityHint, not this text. The
    /// gated verb is computed for the single selected item only, so it stays cheap.
    private var clipboardFooterHint: String {
        // The two ⇧ segments sit side by side on purpose: bare Shift previews, Shift
        // **with a click** picks rows — stated as one contrast so neither reads as a
        // contradiction of the other. Width is load-bearing: the list column is 340pt
        // and this Text has no lineLimit, so a longer string wraps to two lines and
        // eats a row of the fixed-height list. Measured at 11pt system font, this
        // string plus the widest "  ⌘→ edit" suffix renders ~329pt. "select" instead
        // of "pick" pushes it to ~339pt — do not spend that margin without measuring.
        var hint = "\u{2190}\u{2192} filter  \u{2191}\u{2193} move  \u{21B5} paste  \u{21E7}click pick  \u{21E7} preview"
        // Mirror the ⌘→ entry gate, which ignores Cmd+Right while more than one row is
        // selected (guard !hasMultiSelection): don't advertise a shortcut that no-ops
        // mid-multiselect.
        let cursor = selection.cursor
        guard !isEditing, !hasMultiSelection, !items.isEmpty, cursor >= 0, cursor < items.count else { return hint }
        let item = items[cursor]
        // Kind-scope the impure facts so a non-video selection doesn't stat a video path and
        // a non-image selection doesn't build a CGImageSource — this recomputes on every body
        // render (e.g. per search keystroke), so keep it to the fact each kind actually needs.
        let isBitmapImage = item.kind == ClipboardRecord.kindImage && (item.imageData.map(ImageCrop.isBitmapData) ?? false)
        let videoFileExists = item.kind == ClipboardRecord.kindVideo && FileManager.default.fileExists(atPath: ClipboardRecord.videoPath(for: item.contentHash).path)
        if let verb = editActionVerb(for: item, isBitmapImage: isBitmapImage, videoFileExists: videoFileExists) {
            hint += "  \u{2318}\u{2192} \(verb)"
        }
        return hint
    }

    // MARK: - Keyboard Handlers

    private func handleClipboardKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // A drag session owns Esc (it cancels the drag) and other keys — don't let
        // the panel's own handlers fire mid-drag (R9).
        if panel?.isDragSessionActive == true { return .ignored }
        // When editing, let NSTextView handle all keys
        if isEditing { return .ignored }

        switch press.key {
        case .rightArrow:
            // Cmd+Right → enter edit mode (edit text / crop image·gif / trim video)
            if press.modifiers.contains(.command) {
                guard !items.isEmpty, !hasMultiSelection,
                      items.indices.contains(selection.cursor) else { return .ignored }
                let item = items[selection.cursor]
                // Single source of truth for "is this editable via ⌘→" — see EditAction.swift.
                // Kind-scope the impure facts so ⌘→ on a non-video item doesn't stat a video path.
                let isBitmapImage = item.kind == ClipboardRecord.kindImage && (item.imageData.map(ImageCrop.isBitmapData) ?? false)
                let videoFileExists = item.kind == ClipboardRecord.kindVideo && FileManager.default.fileExists(atPath: ClipboardRecord.videoPath(for: item.contentHash).path)
                if editActionVerb(for: item, isBitmapImage: isBitmapImage, videoFileExists: videoFileExists) != nil {
                    enterEditMode()
                    return .handled
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

        // Match on `press.key` and probe modifiers with `.contains` only — arrow events
        // carry `.numericPad` (and sometimes `.function`), so `== .shift` / `.isEmpty`
        // never match (`.claude/rules/swiftui-keypress-gotchas.md`).
        case .downArrow:
            guard !items.isEmpty else { return .handled }
            if press.modifiers.contains(.shift) {
                selection.shiftMove(by: 1, ids: itemIDs)
            } else {
                selection.plainMove(by: 1, ids: itemIDs)
            }
            return .handled

        case .upArrow:
            guard !items.isEmpty else { return .handled }
            if press.modifiers.contains(.shift) {
                selection.shiftMove(by: -1, ids: itemIDs)
            } else {
                selection.plainMove(by: -1, ids: itemIDs)
            }
            return .handled

        case .return:
            pasteSelected()
            return .handled

        case .escape:
            // The Escape ladder advances exactly one VISIBLE step per press: close the
            // large preview → clear the selection → clear the search field → close the
            // panel. `escapeClear` always clears, but reports whether the user could see
            // anything change: a toggled set holding only the cursor row's own ID (what a
            // Shift+Down/Shift+Up round-trip, or a single Shift+Click, leaves behind)
            // renders identically to a bare cursor, so it reports false and this press
            // falls through to the search rung exactly as it does today (R8).
            if largePreviewPanel != nil {
                closeLargePreview()
            } else if !selection.escapeClear(ids: itemIDs) {
                if !searchText.isEmpty {
                    searchText = ""
                } else {
                    panel?.close()
                }
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
        // Command rows are keyed by name, not record ID, so they use the count-only
        // `plainMove` overload — there is no ID list to hand the model, and multi-select
        // is a clipboard-mode concept only (the toggled set stays empty here).
        case .downArrow:
            guard count > 0 else { return .handled }
            selection.plainMove(by: 1, count: count)
            return .handled

        case .upArrow:
            guard count > 0 else { return .handled }
            selection.plainMove(by: -1, count: count)
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
            onReturn: { selectCommand(at: selection.cursor) },
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
                    selection.reset()
                }
                return .handled
            }
            if press.key == .rightArrow {
                if activeSection < cmd.sections.count - 1 {
                    activeSection += 1
                    selection.reset()
                }
                return .handled
            }
        }

        return handleCommandKeyPress(
            press,
            count: activeSectionOptions.count,
            onReturn: { executeSectionOption(at: selection.cursor) },
            onEscape: { returnToCommandList() }
        )
    }

    private func returnToCommandList() {
        panelMode = .commandList
        searchText = "/"
        selection.reset()
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
        selection.reset()

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

            // While editing, follow the edited item to its new index. `collapse` is the
            // right operation, not a bare cursor move: the edit flow is a
            // single-selection flow (⌘→ is gated on !hasMultiSelection), so landing on
            // the edited row with an empty toggled set keeps it that way.
            if isEditing, let targetId = editingItemId,
               let newIndex = items.firstIndex(where: { $0.id == targetId }) {
                selection.collapse(to: newIndex, ids: itemIDs)
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
        // Clamp the indices into the new bounds AND drop toggled IDs whose rows are
        // gone (deleted, filtered out, or aged out) — otherwise a long session's
        // toggled set grows without bound and a re-appearing row would light up again.
        selection.clampAndPrune(ids: itemIDs)

        // Update or close large preview after items change
        if items.isEmpty {
            closeLargePreview()
        } else if selection.cursor < items.count {
            largePreviewPanel?.update(for: items[selection.cursor])
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
        // Relayed arrows go through the same `plainMove` the panel's own arrows use, so
        // the two surfaces can't drift. Deliberate, plan-sanctioned nuance: with a
        // multi-selection active this now collapses to the selection's edge (the panel's
        // semantics) instead of always wrap-moving. Single-selection behavior — the only
        // reachable state before cherry-picking existed — is unchanged.
        case kVK_UpArrow:
            guard !items.isEmpty else { return }
            selection.plainMove(by: -1, ids: itemIDs)
        case kVK_DownArrow:
            guard !items.isEmpty else { return }
            selection.plainMove(by: 1, ids: itemIDs)
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
        let item = items[selection.cursor]
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

        // INVARIANT — the set of editable kinds is defined by `editActionVerb`
        // (EditAction.swift), the shared Cmd+Right entry gate. Every media kind that can
        // enter edit mode must be handled here so the editingText path never clobbers it:
        // kindGif/kindImage save via onGifSave/onImageSave; kindVideo is deliberately
        // absent because VideoTrimView fires onVideoSave directly and never routes through
        // saveEdit — the entry gate and the save routing are different concerns, so
        // editActionVerb returning "edit" for video does NOT mean video flows through here.
        if let item = items.first(where: { $0.id == editingItemId }),
           item.kind == ClipboardRecord.kindGif || item.kind == ClipboardRecord.kindImage {
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
        selection.reset()
    }

    private func saveGifTrim(data: Data) {
        commitMediaEdit(logTag: "saveGifTrim") { db, itemId in
            try ClipboardRecord.updateGifData(id: itemId, newData: data, in: db)
        }
    }

    private func saveImageCrop(data: Data) {
        commitMediaEdit(logTag: "saveImageCrop") { db, itemId in
            try ClipboardRecord.updateImageData(id: itemId, newData: data, in: db)
        }
    }

    /// Shared close-edit-mode + detached-DB-write boilerplate for in-place media
    /// edits (GIF trim/crop, image crop). The video path stays separate — it has
    /// its own file-move/hash/thumbnail flow in `saveVideoTrim`.
    private func commitMediaEdit(logTag: String, update: @escaping @Sendable (Database, Int64) throws -> Void) {
        guard isEditing else { return }
        isEditing = false
        let savedItemId = editingItemId
        editingItemId = nil
        isSearchFocused = true

        guard let itemId = savedItemId else { return }

        Task.detached {
            do {
                try await database.pool.write { db in
                    try update(db, itemId)
                }
            } catch {
                Log.error("PanelView: \(logTag) failed: \(error)")
            }
        }

        // Item moves to top when ValueObservation fires
        selection.reset()
    }

    private func saveVideoTrim(url trimmedURL: URL) {
        // The export runs detached and can complete after edit mode ended (panel
        // closed mid-export). Discarding the save is correct, but the exported temp
        // file must not leak in NSTemporaryDirectory.
        guard isEditing else {
            do { try FileManager.default.removeItem(at: trimmedURL) }
            catch { Log.debug("PanelView: cleanup orphaned export failed: \(error)") }
            return
        }
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

        selection.reset()
    }

    /// Leaves the selection ALONE, deliberately (R9). Every *save* path resets to the
    /// top because the saved item is about to move there; a discard changes nothing in
    /// the list, so resetting here would yank the cursor to row 0 every time the user
    /// escapes out of an edit. There is no selection write here today — don't add one.
    private func discardEdit() {
        isEditing = false
        editingItemId = nil
        editingText = originalText
        isSearchFocused = true
    }

    // MARK: - Actions

    /// The whole selection effect of a row press, applied at mouseDown (KTD6) — before
    /// the drag snapshot, so a press that becomes a drag carries what the user just
    /// selected. Shared by the mouse pipeline and the VoiceOver row actions so the two
    /// can never diverge.
    ///
    /// - Shift press: toggle this row (R1). Ignored while editing (R11), mirroring the
    ///   keyboard and drag guards — a cherry-pick mid-crop has no meaning.
    /// - Plain press: collapse onto this row **only when it is outside** the current
    ///   effective selection (R2). Pressing inside leaves the selection intact, which is
    ///   what makes a plain click paste the whole set and a drag from a selected row
    ///   carry the whole set.
    ///
    /// The plain branch is deliberately NOT guarded on `isEditing`: a plain click
    /// mid-edit still pastes the clicked row, a pre-existing oddity the plan keeps
    /// explicitly out of scope. Only the Shift branch is new, so only it gets the guard.
    private func handleRowPress(at index: Int, isShift: Bool) {
        let ids = itemIDs
        if isShift {
            guard !isEditing else { return }
            selection.shiftClick(at: index, ids: ids)
            return
        }
        guard !selection.selectedIndices(ids: ids).contains(index) else { return }
        selection.collapse(to: index, ids: ids)
    }

    /// Records a drag started on `pressedIndex` should carry. A drag from inside an
    /// active multi-selection carries the whole selection; from outside (or with no
    /// multi-selection) it carries just the pressed row.
    ///
    /// **Side-effect-free (KTD7).** It used to collapse the selection onto the pressed
    /// row itself; that collapse now lives in `handleRowPress`, which runs first on every
    /// press — including presses that never become drags. Keep this a pure read: it is
    /// called from `mouseDown` purely to snapshot a payload, and a mutation here would
    /// fire on gestures (a plain press inside the selection) that must leave the
    /// selection alone.
    ///
    /// Returns [] while editing so rows aren't draggable mid-crop (R11). Evaluated at
    /// mouseDown, so `items` here is the snapshot at gesture start (KTD3).
    private func dragParticipants(pressedIndex: Int) -> [ClipboardRecord] {
        guard !isEditing, items.indices.contains(pressedIndex) else { return [] }
        let ids = itemIDs
        let indices = DragExport.participantIndices(
            pressed: pressedIndex,
            selection: Set(selection.selectedIndices(ids: ids)),
            hasMultiSelection: selection.hasMultiSelection(ids: ids)
        )
        return indices.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

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
        // Resolve indices and records together — the reposition below needs the indices,
        // and `selectedIndices` is already ascending (list order), so this is also the
        // R4 delete order.
        let ids = itemIDs
        let deletedIndices = selection.selectedIndices(ids: ids)
        let selected = deletedIndices.compactMap { items.indices.contains($0) ? items[$0] : nil }
        let toDelete = selected.compactMap(\.id)
        guard !toDelete.isEmpty else { return }

        // Collect video hashes before deletion (needed to find files on disk)
        let videoHashes = selected
            .filter { $0.kind == ClipboardRecord.kindVideo }
            .map(\.contentHash)
        // All selected hashes: purge any drag-out staged copies immediately so a
        // deleted item's file doesn't linger on disk until the age sweep (R14).
        let deletedHashes = selected.map(\.contentHash)

        // Where the cursor lands, as a POST-delete index (R5). The old arithmetic here
        // (`max(anchor, cursor) + 1 - count`) assumed the deletion was one contiguous
        // block; with a cherry-picked set it over-counts the rows removed above the
        // landing row and the cursor drifts up. `indexAfterDeleting` walks the survivors
        // instead, so it is correct for sparse and contiguous deletions alike.
        let newIndex = PanelSelection.indexAfterDeleting(deleted: Set(deletedIndices), count: items.count)

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
                // Purge staged drag-out copies for every deleted item (R14).
                let stagingRoot = DragExport.stagingDirectory
                for hash in deletedHashes {
                    DragExport.purgeStaging(contentHash: hash, root: stagingRoot)
                }
            } catch {
                Log.error("PanelView: deleteSelected failed: \(error)")
            }
        }

        // Collapse rather than just move the cursor: the deleted rows are still in `items`
        // until the observation fires, so leaving them toggled would keep them highlighted
        // (and re-selected for the next Return) in that window.
        selection.collapse(to: newIndex, ids: ids)
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
