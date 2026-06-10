import SwiftUI

/// Skill 安裝引導 sheet。
///
/// 任務單純：告訴使用者「skill 已裝在 ~/.atelio/skills/atelio/，但還要把它接進
/// 你的 AI 的 skill 目錄」，並導流到 Help 看完整指令。本身**不放指令**——指令
/// 單一來源在 `HelpView`，避免日後支援的 CLI 增減造成兩處漂移。
///
/// 觸發語意採中性：不預設使用者要自己接還是叫 AI 接，只把現況講清楚 + 給入口。
///
/// 註：版本控管（skill_notified_version 比對）目前**放空**，每次啟動都會彈，
/// 方便調內容；待文案定稿後再於 `ContentView` 把 gating 接回。
struct SkillSetupSheet: View {
    /// 已安裝的 skill 版本（nil = 解析不到，略過版本行）。由 caller 讀一次傳入，
    /// 避免 view 每次 render 都讀檔。
    let skillVersion: String?
    /// 關閉自己
    let onDismiss: () -> Void
    /// 開啟 Help 視窗（由 caller 注入 openWindow，sheet 本身不直接依賴環境）
    let onOpenHelp: () -> Void

    /// 文字隨 app 字體大小聯動
    @State private var scale = AtelioUIScale()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("讓你的 AI 讀懂 Atelio")
                    .font(scale.font(.title2))
                    .fontWeight(.semibold)

                if let skillVersion {
                    Text("操作手冊 v\(skillVersion)")
                        .font(scale.font(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Atelio 附了一份操作手冊（skill），已經裝在你的電腦上：")
                    .fixedSize(horizontal: false, vertical: true)

                Text("~/.atelio/skills/atelio/")
                    .font(scale.font(.monoCallout))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                Text("""
                最後一步：把它接進你的 AI 的 skill 目錄，主 AI 才知道怎麼操作 \
                Atelio。你可以自己接，也可以把說明整段複製給 AI 讓它幫你接 —— \
                兩種做法的指令都在「安裝說明」裡。
                """)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(scale.font(.body))

            HStack {
                Spacer()
                Button("知道了") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("查看安裝說明") {
                    onOpenHelp()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

#Preview {
    SkillSetupSheet(skillVersion: "0.1.0", onDismiss: {}, onOpenHelp: {})
}
