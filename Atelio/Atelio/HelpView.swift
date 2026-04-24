import SwiftUI

/// Atelio 說明視窗：靜態內容，列出基本 CLI 指令與快捷鍵。
///
/// 使用者畫像以寫程式的人為主，詳細資訊在 source repository；此處內容
/// 以「點了看完不覺得壞」為目標，不追求完整手冊。
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                Text("""
                AI CLI worker 容器。在終端機視窗裡跑 Claude Code / Codex \
                等 AI CLI 作為 worker，由主 AI 透過 CLI 指令控制，實現多 \
                session 並行協作。
                """)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

                section(title: "基本用法", rows: [
                    ("atelio open <name>", "開新 session"),
                    ("atelio close <name>", "關閉 session"),
                    ("atelio list", "列出所有 sessions"),
                    ("atelio dispatch <name> <text>", "送指令並等待"),
                    ("atelio screen <name>", "看當前畫面"),
                ])

                section(title: "快捷鍵", rows: [
                    ("⌘=", "放大文字"),
                    ("⌘-", "縮小文字"),
                    ("⌘0", "重設文字大小"),
                    ("⌘W", "關閉視窗（App 繼續運行）"),
                    ("⌘Q", "結束 Atelio"),
                ])

                Text("詳細說明請參考專案 source repository。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        Text("Atelio")
            .font(.largeTitle)
            .fontWeight(.semibold)
    }

    @ViewBuilder
    private func section(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.0)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 220, alignment: .leading)
                        Text(row.1)
                            .foregroundStyle(.secondary)
                    }
                    // VoiceOver：把指令與說明合併成一列讀出（否則會拆兩元素）
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

#Preview {
    HelpView()
        .frame(width: 500, height: 600)
}
