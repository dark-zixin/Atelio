import SwiftUI

/// 假終端色塊，用於 Layout 開發階段的視覺驗證
struct FakeTerminalView: View {
    let name: String
    let color: Color
    let isMain: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.3))
            RoundedRectangle(cornerRadius: 4)
                .stroke(isMain ? Color.white : color, lineWidth: isMain ? 2 : 1)

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                if isMain {
                    Text("主位")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
            }
        }
    }
}

/// 預定義的終端色彩
let terminalColors: [Color] = [
    .blue, .green, .orange, .purple, .red, .cyan,
    .mint, .pink, .indigo, .yellow
]
