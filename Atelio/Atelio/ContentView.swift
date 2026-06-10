import SwiftUI
import AtelioShared

struct ContentView: View {
    @Bindable var manager: TerminalManager
    @Environment(\.openWindow) private var openWindow

    /// 是否顯示 skill 安裝引導 sheet。
    @State private var showSkillSetup = false

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
            // 版本控管暫時放空：每次開 App 都彈，方便調 sheet / Help 內容。
            // 定稿後改成比對「已安裝 skill 版本」與 config 的 skill_notified_version，
            // 不同才彈（首次 = 欄位不存在），dismiss 時寫回當前版本。
            showSkillSetup = true
        }
        .sheet(isPresented: $showSkillSetup) {
            SkillSetupSheet(
                skillVersion: AtelioPaths.installedSkillVersion(),
                onDismiss: { showSkillSetup = false },
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
