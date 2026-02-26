import SwiftUI

struct CommandRowView: View {
    let command: any SlashCommand
    let isCursor: Bool

    static let rowHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(command.displayName)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

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
