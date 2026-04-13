import SwiftUI

/// 底部縮小列，顯示被最小化的終端
struct MinimizedBar: View {
    let terminals: [MinimizedTerminalInfo]
    var onRestore: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(terminals, id: \.name) { terminal in
                MinimizedTerminalChip(
                    name: terminal.name,
                    status: terminal.status
                ) {
                    onRestore?(terminal.name)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
    }
}

/// 縮小列中的終端資訊
struct MinimizedTerminalInfo: Equatable {
    let name: String
    let status: String  // "idle" / "busy"
}

/// 縮小列中的終端標籤
private struct MinimizedTerminalChip: View {
    let name: String
    let status: String
    let onTap: () -> Void

    private var statusColor: Color {
        switch status {
        case "busy": return .orange
        case "idle": return .gray
        case "unowned": return .yellow
        case "exited": return .red
        default: return .gray
        }
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)

                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)

                Text("(\(status))")
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.white.opacity(0.1) : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
