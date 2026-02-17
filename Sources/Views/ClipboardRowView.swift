import SwiftUI

struct ClipboardRowView: View {
    let item: ClipboardRecord
    let isSelected: Bool
    let isCursor: Bool      // true for the keyboard-focus row
    let shortcutIndex: Int? // 0-8 for Cmd+1 through Cmd+9, nil if beyond range

    /// Fixed row height: 24px icon + 4px padding each side = 32px.
    /// Used by ClipboardPanelView to compute the list area height.
    static let rowHeight: CGFloat = 32

    private static let appIconCache = NSCache<NSString, NSImage>()

    var body: some View {
        HStack(spacing: 8) {
            // Source app icon
            appIcon
                .frame(width: 24, height: 24)

            // Content (truncated)
            contentView
                .frame(maxWidth: .infinity, alignment: .leading)

            // Shortcut label or return arrow
            shortcutLabel
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .frame(height: Self.rowHeight)
    }

    // MARK: - App Icon

    @ViewBuilder
    private var appIcon: some View {
        if let bundleId = item.sourceBundleId, let icon = Self.resolveAppIcon(bundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            let iconName = switch item.kind {
            case ClipboardRecord.kindGif: "play.rectangle"
            case ClipboardRecord.kindImage: "photo"
            default: "doc.on.clipboard"
            }
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch item.kind {
        case ClipboardRecord.kindGif:
            if let data = item.imageData, let nsImage = NSImage(data: data) {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                let durationStr = ClipboardRecord.gifMetadata(from: data).map { String(format: "%.1fs", $0.duration) }
                let detail = durationStr.map { "\(sizeStr), \($0)" } ?? sizeStr
                Text("GIF: \(w)×\(h) (\(detail))")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text("GIF")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
            }
        case ClipboardRecord.kindImage:
            if let data = item.imageData, let nsImage = NSImage(data: data) {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                Text("Image: \(w)×\(h) (\(sizeStr))")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text("Image")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
            }
        default:
            Text(item.plainText?.prefix(100) ?? "")
                .lineLimit(1)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Shortcut Label

    @ViewBuilder
    private var shortcutLabel: some View {
        if isCursor {
            Image(systemName: "return")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        } else if isSelected {
            // Multi-selected but not cursor — no label, just highlight
            EmptyView()
        } else if let idx = shortcutIndex {
            Text("\u{2318}\(idx + 1)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - App Icon Resolution

    private static func resolveAppIcon(bundleId: String) -> NSImage? {
        let cacheKey = bundleId as NSString
        if let cached = appIconCache.object(forKey: cacheKey) {
            return cached
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let size = NSSize(width: 24, height: 24)
        let resized = NSImage(size: size)
        resized.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1.0)
        resized.unlockFocus()

        appIconCache.setObject(resized, forKey: cacheKey)
        return resized
    }

}
