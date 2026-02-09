import SwiftUI

struct PreviewPanel: View {
    let item: ClipboardRecord?

    var body: some View {
        VStack(spacing: 0) {
            if let item = item {
                previewContent(for: item)
                Spacer(minLength: 0)
                Divider()
                metadataBar(for: item)
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

    private func textPreview(for item: ClipboardRecord) -> some View {
        ScrollView {
            Text(item.plainText ?? "")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
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
            if item.kind == ClipboardRecord.kindText, let text = item.plainText {
                let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                Text("\(words) words; \(text.count) chars")
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
