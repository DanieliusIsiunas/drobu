import SwiftUI
import GRDB

struct ClipboardPanelView: View {
    let database: AppDatabase

    @State private var searchText = ""
    @State private var items: [ClipboardRecord] = []
    @State private var anchor = 0      // where Shift-select started
    @State private var cursor = 0      // current keyboard position
    @State private var observation: AnyDatabaseCancellable?
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
        guard cursor < items.count else { return nil }
        return items[cursor]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field (full width)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Split layout: list | preview
            if items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    // Left panel: item list
                    itemList
                        .frame(width: 340)

                    Divider()

                    // Right panel: preview
                    PreviewPanel(item: previewItem, selectionCount: selectedItems.count)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(width: 780, height: 460)
        .background(VisualEffectBackground())
        .onAppear {
            startObservation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
                if let buffered = panel?.consumeBufferedKeystrokes(), !buffered.isEmpty {
                    searchText = buffered
                }
            }
        }
        .onDisappear {
            observation?.cancel()
            observation = nil
            searchText = ""
            anchor = 0
            cursor = 0
        }
        .onChange(of: searchText) { _, _ in
            anchor = 0
            cursor = 0
            startObservation()
        }
        .onKeyPress(phases: [.down, .repeat]) { press in
            switch press.key {
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
                if hasMultiSelection {
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
        // Cmd+1 through Cmd+9 shortcuts
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789"), phases: .down) { press in
            guard press.modifiers == .command,
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

    // MARK: - Item List

    private var itemList: some View {
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
                guard newValue < items.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(items[newValue].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text(searchText.isEmpty ? "Copy something to get started" : "No matches found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Database Observation

    private func startObservation() {
        observation?.cancel()
        let query = searchText
        let pool = database.pool

        observation = ValueObservation.tracking { db in
            try ClipboardRecord.search(query: query, in: db)
        }
        .start(in: pool, onError: { _ in }, onChange: { [self] newItems in
            items = newItems
            let maxIdx = max(0, newItems.count - 1)
            if anchor > maxIdx { anchor = maxIdx }
            if cursor > maxIdx { cursor = maxIdx }
        })
    }

    // MARK: - Actions

    private func pasteSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        if selected.count == 1 {
            panel?.pasteItem(selected[0])
        } else {
            panel?.pasteItems(selected)
        }
    }

    private func deleteSelected() {
        let toDelete = selectedItems.compactMap(\.id)
        guard !toDelete.isEmpty else { return }

        let afterIndex = max(anchor, cursor) + 1
        let newIndex = afterIndex < items.count
            ? afterIndex - toDelete.count
            : max(0, min(anchor, cursor) - 1)

        Task.detached {
            try? await database.pool.write { db in
                for id in toDelete {
                    try ClipboardRecord.deleteById(id, in: db)
                }
            }
        }

        let safeIndex = max(0, min(newIndex, items.count - toDelete.count - 1))
        anchor = safeIndex
        cursor = safeIndex
    }
}

// MARK: - Visual Effect Background

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
