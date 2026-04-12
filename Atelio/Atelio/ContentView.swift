import SwiftUI

struct ContentView: View {
    @Bindable var manager: TerminalManager

    var body: some View {
        Group {
            if manager.sessions.isEmpty {
                emptyState
            } else {
                WorkspaceView(manager: manager)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
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
