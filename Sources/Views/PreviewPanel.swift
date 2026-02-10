import SwiftUI

struct PreviewPanel: View {
    let item: ClipboardRecord?
    var selectionCount: Int = 1
    @Binding var isEditing: Bool
    @Binding var editingText: String
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if selectionCount > 1 {
                multiSelectSummary
            } else if let item = item {
                VStack(spacing: 0) {
                    previewContent(for: item)
                    Spacer(minLength: 0)
                    metadataBar(for: item)
                }
                .chromaSweepBorder(isActive: isEditing)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview Content

    @ViewBuilder
    private func previewContent(for item: ClipboardRecord) -> some View {
        switch item.kind {
        case ClipboardRecord.kindImage:
            imagePreview(for: item)
        default:
            textPreview(for: item)
        }
    }

    @ViewBuilder
    private func textPreview(for item: ClipboardRecord) -> some View {
        if isEditing {
            EditableTextView(
                text: $editingText,
                onSave: onSave,
                onDiscard: onDiscard
            )
        } else {
            ScrollView {
                Text(item.plainText ?? "")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        }
    }

    private func imagePreview(for item: ClipboardRecord) -> some View {
        Group {
            if let data = item.imageData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("Unable to load image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Metadata Bar

    private func metadataBar(for item: ClipboardRecord) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if item.kind == ClipboardRecord.kindText {
                // Use editingText for live counts during editing, otherwise item text
                let displayText = isEditing ? editingText : (item.plainText ?? "")
                let words = displayText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                Text("\(words) words; \(displayText.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.kind == ClipboardRecord.kindImage, let data = item.imageData, let nsImage = NSImage(data: data) {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                Text("\(w)x\(h) (\(sizeStr))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Copied \(item.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Multi-Select Summary

    private var multiSelectSummary: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("\(selectionCount) items selected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Press Return to paste all")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "eye")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("Select an item to preview")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
