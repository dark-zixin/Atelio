import SwiftUI

/// 終端視窗的標題列
///
/// 顯示名稱、用途，提供 layout 選擇、最小化、最大化、關閉按鈕。
struct TerminalTitleBar: View {
    let name: String
    let purpose: String
    let status: String
    let isFocused: Bool
    let isMaximized: Bool
    let availableModes: [LayoutMode]

    /// 選擇 layout 模式（此終端成為主位）
    var onSelectLayout: ((LayoutMode) -> Void)?
    private var statusColor: Color {
        switch status {
        case "busy": return .orange
        case "idle": return .gray
        case "unowned": return .yellow
        case "exited": return .red
        default: return .gray
        }
    }

    var onMinimize: (() -> Void)?
    var onMaximize: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // 左側：名稱和用途
            HStack(spacing: 6) {
                Circle()
                    .fill(isFocused ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Text(name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                if !purpose.isEmpty {
                    Text("(\(purpose))")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                Text("· \(status)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            // 右側：操作按鈕
            HStack(spacing: 6) {
                // Layout 選擇器
                LayoutPickerView(
                    availableModes: availableModes,
                    onSelect: { mode in onSelectLayout?(mode) }
                )

                // 最小化
                TitleBarButton(symbol: "minus", color: .yellow) {
                    onMinimize?()
                }

                // 最大化 / 還原
                TitleBarButton(
                    symbol: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    color: .green
                ) {
                    onMaximize?()
                }

                // 關閉
                TitleBarButton(symbol: "xmark", color: .red) {
                    onClose?()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isFocused ? Color.white.opacity(0.1) : Color.white.opacity(0.05))
    }
}

/// Title bar 上的按鈕
private struct TitleBarButton: View {
    let symbol: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered ? color : .gray)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
