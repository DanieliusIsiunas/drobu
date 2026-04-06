import SwiftUI

struct ClipboardRowView: View {
    let item: ClipboardRecord
    let isSelected: Bool
    let isCursor: Bool      // true for the keyboard-focus row
    let shortcutIndex: Int? // 0-8 for Cmd+1 through Cmd+9, nil if beyond range

    /// Fixed row height: 24px icon + 4px padding each side = 32px.
    /// Used by PanelView to compute the list area height.
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Press Return to paste")
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
            case ClipboardRecord.kindVideo: "video.fill"
            case ClipboardRecord.kindFile:
                (item.plainText?.contains("\n") == true) ? "doc.on.doc.fill" : "doc.fill"
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
            Text(item.plainText ?? "GIF")
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case ClipboardRecord.kindImage:
            Text(item.plainText ?? "Image")
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case ClipboardRecord.kindVideo:
            Text(item.plainText ?? "Screen Recording")
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case ClipboardRecord.kindFile:
            Text(Self.fileDisplayText(for: item.plainText))
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1)
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

    // MARK: - File Display

    private static func fileDisplayText(for plainText: String?) -> String {
        guard let text = plainText, !text.isEmpty else { return "File:" }
        let paths = text.split(separator: "\n")
        if paths.count == 1 {
            guard let first = paths.first else { return "File" }
            return "File: \(URL(fileURLWithPath: String(first)).lastPathComponent)"
        }
        return "File: \(paths.count) files"
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
