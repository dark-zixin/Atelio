import SwiftUI

struct ContentView: View {
    @Bindable var manager: TerminalManager

    var body: some View {
        Group {
            if manager.sessions.isEmpty {
                emptyState
            } else {
                terminalTabs
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

    // MARK: - 終端分頁

    private var terminalTabs: some View {
        TabView {
            ForEach(sortedSessions, id: \.name) { session in
                TerminalViewWrapper(session: session)
                    .tabItem {
                        Label(session.name, systemImage: "terminal")
                    }
            }
        }
    }

    private var sortedSessions: [TerminalSession] {
        manager.sessions.values.sorted { $0.name < $1.name }
    }
}
