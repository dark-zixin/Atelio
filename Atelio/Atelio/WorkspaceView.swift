import SwiftUI
import Combine

/// 主工作區 View，取代 TabView
///
/// 用 LayoutTemplate 排列多個 TerminalWindowView，
/// 底部顯示最小化的終端列。
struct WorkspaceView: View {
    @Bindable var manager: TerminalManager
    @State private var workspace = WorkspaceState()
    /// 定期刷新標題列狀態（每 2 秒 +1，觸發 body 重新計算）
    @State private var statusTick = 0

    /// 所有 session 按建立時間排序
    private var sortedSessions: [TerminalSession] {
        manager.sessions.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// 所有 session 名稱（排序後）
    private var allNames: [String] {
        sortedSessions.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 最大化模式
            if let maxName = workspace.maximizedTerminalName,
               let session = manager.sessions[maxName] {
                TerminalWindowView(
                    session: session,
                    isFocused: true,
                    isMaximized: true,
                    availableModes: LayoutMode.allCases,
                    onMaximize: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            workspace.toggleMaximize(maxName)
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            workspace.toggleMaximize(maxName)
                            closeTerminal(maxName)
                        }
                    }
                )
            } else {
                // 正常 layout
                layoutContent
            }

            // 底部縮小列
            let minimized = workspace.minimizedTerminalNames(from: allNames)
            if !minimized.isEmpty {
                MinimizedBar(
                    terminals: minimized.compactMap { name in
                        guard let session = manager.sessions[name] else { return nil }
                        return MinimizedTerminalInfo(
                            name: name,
                            status: session.status.rawValue
                        )
                    },
                    onRestore: { name in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            workspace.restore(name)
                        }
                    }
                )
            }
        }
        .onChange(of: manager.sessions.count) {
            syncWorkspaceState()
        }
        .onAppear {
            syncWorkspaceState()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            statusTick &+= 1
        }
        // 讓 SwiftUI 感知 statusTick 變化，觸發 body 重新計算
        .overlay { let _ = statusTick }
    }

    // MARK: - Layout 內容

    @ViewBuilder
    private var layoutContent: some View {
        let normalNames = workspace.normalTerminalNames(from: allNames)
        let mainIndex: Int = {
            guard let mainName = workspace.mainTerminalName,
                  let idx = normalNames.firstIndex(of: mainName) else { return 0 }
            return idx
        }()
        let slots = LayoutTemplate.generateSlots(
            mode: workspace.layoutMode,
            count: normalNames.count,
            mainIndex: mainIndex
        )

        GeometryReader { geo in
            ZStack {
                if normalNames.isEmpty {
                    // 所有終端都被最小化
                    emptyLayoutState
                } else {
                    ForEach(Array(zip(normalNames, slots)), id: \.0) { name, slot in
                        if let session = manager.sessions[name] {
                            let slotWidth = slot.width * geo.size.width - 2
                            let slotHeight = slot.height * geo.size.height - 2

                            TerminalWindowView(
                                session: session,
                                isFocused: workspace.focusedTerminalName == name,
                                isMaximized: false,
                                availableModes: LayoutMode.allCases,
                                onSelectLayout: { mode in
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        workspace.selectLayout(mode: mode, mainTerminal: name)
                                    }
                                },
                                onMinimize: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        workspace.minimize(name)
                                    }
                                },
                                onMaximize: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        workspace.toggleMaximize(name)
                                    }
                                },
                                onClose: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        closeTerminal(name)
                                    }
                                },
                                onTap: {
                                    workspace.focusedTerminalName = name
                                }
                            )
                            .frame(width: slotWidth, height: slotHeight)
                            .position(
                                x: (slot.x + slot.width / 2) * geo.size.width,
                                y: (slot.y + slot.height / 2) * geo.size.height
                            )
                        }
                    }
                }
            }
        }
    }

    private var emptyLayoutState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.gray)
            Text("所有終端已最小化")
                .foregroundStyle(.gray)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 同步

    /// 同步 WorkspaceState 和 TerminalManager 的 sessions
    ///
    /// CLI 操作（open/close）會改變 manager.sessions，
    /// 這裡確保 workspace 的 displayStates 跟著同步。
    private func syncWorkspaceState() {
        let currentNames = Set(allNames)
        let trackedNames = Set(workspace.displayStates.keys)

        // 新增的終端 → 註冊
        for name in currentNames.subtracting(trackedNames) {
            workspace.registerTerminal(name)
            // 第一個終端自動取得焦點
            if workspace.focusedTerminalName == nil {
                workspace.focusedTerminalName = name
            }
        }

        // 被移除的終端 → 清理
        for name in trackedNames.subtracting(currentNames) {
            workspace.removeTerminal(name)
        }
    }

    // MARK: - 操作

    private func closeTerminal(_ name: String) {
        workspace.removeTerminal(name)
        // 透過 manager 關閉（直接 forceClose，不走兩段式確認）
        if let session = manager.sessions[name] {
            session.forceClose()
            manager.sessions.removeValue(forKey: name)
        }
    }
}
