import SwiftUI
import GRDB

struct ClipboardPanelView: View {
    let database: AppDatabase

    @State private var searchText = ""
    @State private var items: [ClipboardRecord] = []
    @State private var selectedIndex = 0
    @State private var observation: AnyDatabaseCancellable?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.floatingPanel) private var panelWrapper

    private var panel: FloatingPanel? { panelWrapper.panel }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
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

            // List or empty state
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRowView(item: item, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        pasteSelected()
                                    }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 620, height: 460)
        .background(VisualEffectBackground())
        .onAppear {
            startObservation()
            // Focus search field after a short delay (NSHostingView needs time to wire responder chain)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
                // Consume any buffered keystrokes
                if let buffered = panel?.consumeBufferedKeystrokes(), !buffered.isEmpty {
                    searchText = buffered
                }
            }
        }
        .onDisappear {
            observation?.cancel()
            observation = nil
            searchText = ""
            selectedIndex = 0
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
            startObservation()
        }
        .onKeyPress(.downArrow) {
            if !items.isEmpty {
                selectedIndex = (selectedIndex + 1) % items.count
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !items.isEmpty {
                selectedIndex = (selectedIndex - 1 + items.count) % items.count
            }
            return .handled
        }
        .onKeyPress(.return) {
            pasteSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            if !searchText.isEmpty {
                searchText = ""
            } else {
                panel?.close()
            }
            return .handled
        }
        .onKeyPress(.deleteForward) {
            deleteSelected()
            return .handled
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
            if selectedIndex >= newItems.count {
                selectedIndex = max(0, newItems.count - 1)
            }
        })
    }

    // MARK: - Actions

    private func pasteSelected() {
        guard selectedIndex < items.count else { return }
        panel?.pasteItem(items[selectedIndex])
    }

    private func deleteSelected() {
        guard selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        guard let id = item.id else { return }
        Task.detached {
            try? await database.pool.write { db in
                try ClipboardRecord.deleteById(id, in: db)
            }
        }
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
