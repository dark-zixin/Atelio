import SwiftUI
import AtelioShared

struct ContentView: View {
    @Bindable var manager: TerminalManager
    @Environment(\.openWindow) private var openWindow

    /// skill 安裝引導 sheet 的呈現內容；nil = 不顯示。
    ///
    /// 用單一 item 攜帶版本與首次/更新旗標，避免多個 @State 在 sheet 呈現當下被
    /// 讀到不一致的值（先前用兩個 @State + isPresented，sheet 會讀到 isUpdate 舊值）。
    @State private var skillSetup: SkillSetupContext?

    var body: some View {
        Group {
            if manager.sessions.isEmpty {
                emptyState
            } else {
                WorkspaceView(manager: manager)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            // 版本 gating：比對已安裝 skill 版本與 config 記錄的 skill_notified_version。
            // - 首次（從未通知，欄位為 nil）一定彈
            // - 之後只有 skill 版本實際變動才彈（App 更新帶新手冊）
            // - 版本解析不到時：僅首次仍彈一次做 onboarding；已有記錄則不再騷擾
            let current = AtelioPaths.installedSkillVersion()
            let notified = AtelioConfig.skillNotifiedVersion
            let shouldShow = (notified == nil) || (current != nil && current != notified)
            if shouldShow {
                skillSetup = SkillSetupContext(skillVersion: current, isUpdate: notified != nil)
            }
        }
        .sheet(item: $skillSetup) { ctx in
            SkillSetupSheet(
                skillVersion: ctx.skillVersion,
                isUpdate: ctx.isUpdate,
                onDismiss: {
                    // 記下「這個版本已提示過」；解析不到時寫 sentinel，避免每次啟動重彈
                    AtelioConfig.setSkillNotifiedVersion(ctx.skillVersion ?? "unknown")
                    skillSetup = nil
                },
                onOpenHelp: { openWindow(id: "help") }
            )
        }
    }

    // MARK: - 空狀態

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("等待終端連線")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("使用 atelio open <name> 開啟終端")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// skill 安裝引導 sheet 的呈現內容。把版本與首次/更新旗標綁成單一 item，
/// 配 `.sheet(item:)` 確保呈現當下資料一致。
private struct SkillSetupContext: Identifiable {
    let id = UUID()
    /// 已安裝 skill 版本（nil = 解析不到）
    let skillVersion: String?
    /// true = 版本更新情境；false = 首次安裝
    let isUpdate: Bool
}
