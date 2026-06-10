import SwiftUI
import AppKit
import AtelioShared

/// Atelio 說明視窗：靜態內容，列出基本 CLI 指令與快捷鍵。
///
/// 使用者畫像以寫程式的人為主，詳細資訊在 source repository；此處內容
/// 以「點了看完不覺得壞」為目標，不追求完整手冊。
struct HelpView: View {
    /// 文字隨 app 字體大小聯動
    @State private var scale = AtelioUIScale()

    /// 已安裝 skill 版本（onAppear 讀一次，避免每次 render 都讀檔）
    @State private var skillVersion = "—"

    /// app 版本（直接讀 bundle，in-memory 無檔案 I/O）
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scale.scaled(24)) {
                header

                Text("""
                AI CLI worker 容器。在終端機視窗裡跑 Claude Code / Codex \
                等 AI CLI 作為 worker，由主 AI 透過 CLI 指令控制，實現多 \
                session 並行協作。
                """)
                .font(scale.font(.body))
                .fixedSize(horizontal: false, vertical: true)

                skillSetupSection

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
                    .font(scale.font(.footnote))
                    .foregroundStyle(.secondary)

                // 版本資訊：app 與 skill 兩個版本各自存在、一起出貨但號碼不同。
                Text("Atelio \(appVersion) · 操作手冊 v\(skillVersion)")
                    .font(scale.font(.footnote))
                    .foregroundStyle(.tertiary)
            }
            .padding(scale.scaled(24))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 視窗寬度跟字體等比：給 ScrollView 定寬，搭配 help 視窗的
        // .windowResizability(.contentSize)，字體放大時視窗等比變寬，欄寬 220
        // 與視窗 500 的比例恆定，右側說明欄不會被擠到逐字斷行。高度維持固定、
        // 垂直溢出由捲動吸收（避免大字體把視窗撐到超出螢幕）。
        .frame(width: scale.scaled(500))
        .onAppear {
            skillVersion = AtelioPaths.installedSkillVersion() ?? "—"
        }
    }

    private var header: some View {
        Text("Atelio")
            .font(scale.font(.largeTitle))
            .fontWeight(.semibold)
    }

    // MARK: - 讓 AI 讀懂 Atelio

    /// Skill 安裝段落：skill 已鏡像到 ~/.atelio/skills/atelio/，剩最後一步要把它
    /// 接進主 AI 的 skill 目錄。提供兩種「給法」（複製給 AI / 自己接），各配複製鈕。
    /// 指令以此處為唯一來源，SkillSetupSheet 只導流到這裡。
    private var skillSetupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("讓 AI 讀懂 Atelio")
                .font(scale.font(.headline))

            Text("""
            操作手冊（skill）已裝在 ~/.atelio/skills/atelio/。把它接進你的 AI 的 \
            skill 目錄，主 AI 才知道怎麼操作 Atelio。以下任選一種：把說明複製給 \
            AI 讓它幫你接，或自己跑指令。
            """)
            .font(scale.font(.callout))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            CodeBlock(label: "複製給 AI（貼進任何 AI 對話）",
                      code: Self.aiSetupPrompt, scale: scale)
            CodeBlock(label: "或自己接（在終端執行）",
                      code: Self.diySymlinkCommands, scale: scale)
        }
    }

    /// 複製給 AI 的自帶上下文 prompt：讓 AI 自己判斷該接到哪個 skill 目錄
    /// （順帶解掉我們對 Codex/Gemini 路徑不確定的問題）。
    private static let aiSetupPrompt = """
    我在用 Atelio（管理多個 AI CLI worker 的 macOS app）。它附了一份操作手冊（skill），已裝在 ~/.atelio/skills/atelio/。

    請把這份 skill 接到「你自己」的 skill 搜尋目錄，讓你之後讀得到它：
    - Claude Code 通常是 ~/.claude/skills/
    - Codex / Gemini 通常是 ~/.agents/skills/
    依你實際的 skill 目錄調整。建議用 symlink（ln -s），這樣 Atelio 之後更新你會自動拿到最新版。接好後讀 ~/.atelio/skills/atelio/SKILL.md 確認可存取。
    """

    /// 自己接的 symlink 指令（CC 路徑較確定，Codex/Gemini 共用 ~/.agents/ 為推測）。
    private static let diySymlinkCommands = """
    # Claude Code
    ln -sf ~/.atelio/skills/atelio ~/.claude/skills/atelio
    # Codex / Gemini（共用 ~/.agents/）
    ln -sf ~/.atelio/skills/atelio ~/.agents/skills/atelio
    """

    @ViewBuilder
    private func section(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(scale.font(.headline))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.0)
                            .font(scale.font(.monoBody))
                            .frame(width: scale.scaled(220), alignment: .leading)
                        Text(row.1)
                            .font(scale.font(.body))
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

/// 等寬程式碼區塊 + 複製鈕。
///
/// 複製後按鈕短暫切到「已複製 ✓」再復原，給使用者明確的成功回饋
/// （borderless 按鈕本身按了沒有狀態變化，使用者無從得知有沒有複製到）。
/// 圖示用 SF Symbol `.replace` 轉場，按下當下即有動態。
private struct CodeBlock: View {
    let label: String
    let code: String
    /// 沿用父層同一個縮放來源，字級跟著 app 字體聯動
    let scale: AtelioUIScale

    /// 是否處於「已複製」短暫狀態
    @State private var copied = false
    /// 復原 task：連點時取消重排，避免閃爍或提早復原
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(scale.font(.subheadline))
                    .fontWeight(.medium)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "已複製" : "複製",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(scale.font(.caption))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
            }
            // 固定列高：doc.on.doc / checkmark 兩個 symbol 高度不同，切換時會讓整列
            // 高度變動、連帶下方程式碼區塊上下跳。固定高度後外部佈局恆定（frame 比
            // 內容大、不裁切，內容置中）。
            .frame(height: scale.scaled(18))
            Text(code)
                .font(scale.font(.monoCallout))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        withAnimation { copied = true }

        revertTask?.cancel()
        revertTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { copied = false }
        }
    }
}
