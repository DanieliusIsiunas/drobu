import SwiftUI

struct CommandItemRow: View {
    let label: String
    let icon: String?
    let isCursor: Bool
    var isDestructive: Bool = false

    static let rowHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            if let iconName = icon {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(isDestructive ? .red : .secondary)
                    .frame(width: 24, height: 24)
            } else {
                Spacer().frame(width: 24)
            }

            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(isDestructive ? .red : .primary)
                .lineLimit(1)

            Spacer()

            if isCursor {
                Image(systemName: "return")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isCursor ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .frame(height: Self.rowHeight)
    }
}
