import SwiftUI

struct ClipboardRowView: View {
    let item: ClipboardRecord
    let isSelected: Bool

    private static let thumbnailCache = NSCache<NSString, NSImage>()

    var body: some View {
        HStack(spacing: 10) {
            contentView
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if let app = item.sourceApp {
                    Text(app)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.kind {
        case ClipboardRecord.kindImage:
            if let imageData = item.imageData, let thumbnail = Self.thumbnail(for: imageData, hash: item.contentHash) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 48)
                    .cornerRadius(4)
            } else {
                Label("Image", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        default:
            Text(item.plainText?.prefix(100) ?? "")
                .lineLimit(2)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    /// Generate and cache thumbnails for image items.
    private static func thumbnail(for data: Data, hash: String) -> NSImage? {
        let cacheKey = hash as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let image = NSImage(data: data) else { return nil }

        let maxDimension: CGFloat = 96
        let ratio = min(maxDimension / image.size.width, maxDimension / image.size.height, 1.0)
        let newSize = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)

        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        thumbnail.unlockFocus()

        thumbnailCache.setObject(thumbnail, forKey: cacheKey)
        return thumbnail
    }
}
