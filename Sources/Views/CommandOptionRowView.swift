import SwiftUI

struct CommandOptionRowView: View {
    let option: CommandOption
    let isCursor: Bool

    static let rowHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            if let iconName = option.icon {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(option.isDestructive ? .red : .secondary)
                    .frame(width: 24, height: 24)
            } else {
                Spacer().frame(width: 24)
            }

            Text(option.label)
                .font(.system(size: 15))
                .foregroundStyle(option.isDestructive ? .red : .primary)
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
