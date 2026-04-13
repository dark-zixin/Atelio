import SwiftUI

/// 假終端色塊
struct PreviewTerminalView: View {
    let name: String
    let color: Color
    let isMain: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.3))
            RoundedRectangle(cornerRadius: 4)
                .stroke(isMain ? Color.white : color, lineWidth: isMain ? 2 : 1)
            if isMain {
                Text("主位")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
        }
    }
}

/// 終端資料
struct PreviewTerminal: Identifiable {
    let id = UUID()
    let name: String
    let purpose: String
    let color: Color
    var status: String = "idle"
}

/// Preview App 主畫面
struct PreviewContentView: View {
    @State private var workspace = WorkspaceState()
    @State private var terminals: [PreviewTerminal] = [
        PreviewTerminal(name: "Claude Code", purpose: "主力開發", color: .blue),
        PreviewTerminal(name: "Codex Review", purpose: "code review", color: .green),
        PreviewTerminal(name: "Gemini", purpose: "文件生成", color: .orange),
    ]
    @State private var nextIndex = 4

    private let availableColors: [Color] = [.purple, .red, .cyan, .mint, .pink, .indigo, .yellow]

    var body: some View {
        VStack(spacing: 0) {
            // 工具列
            toolbar

            Divider()

            // 主內容
            if let maxName = workspace.maximizedTerminalName,
               let terminal = terminals.first(where: { $0.name == maxName }) {
                // 最大化模式
                maximizedView(terminal: terminal)
            } else {
                // 正常 layout
                layoutView
            }

            // 底部縮小列
            let minimized = minimizedTerminals
            if !minimized.isEmpty {
                MinimizedBar(
                    terminals: minimized.map {
                        MinimizedTerminalInfo(name: $0.name, status: $0.status)
                    },
                    onRestore: { name in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            workspace.restore(name)
                        }
                    }
                )
            }
        }
        .background(Color.black)
        .onAppear {
            workspace.layoutMode = .topMain
            workspace.mainTerminalName = "Claude Code"
            workspace.focusedTerminalName = "Claude Code"
            for t in terminals {
                workspace.registerTerminal(t.name)
            }
        }
    }

    // MARK: - 工具列

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Atelio Preview")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Divider().frame(height: 16)

            // Layout 模式切換
            ForEach(LayoutMode.allCases) { mode in
                Button(mode.displayName) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        workspace.layoutMode = mode
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(workspace.layoutMode == mode ? .white : .gray)
                .font(.system(size: 11))
            }

            Divider().frame(height: 16)

            // 新增終端
            Button("+ 新增終端") {
                addTerminal()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .font(.system(size: 11))

            Spacer()

            Text("終端數：\(terminals.count)（顯示 \(normalTerminals.count)）")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Layout 內容

    private var layoutView: some View {
        let names = normalTerminals.map(\.name)
        let mainIndex: Int = {
            guard let mainName = workspace.mainTerminalName,
                  let idx = names.firstIndex(of: mainName) else { return 0 }
            return idx
        }()
        let slots = LayoutTemplate.generateSlots(
            mode: workspace.layoutMode,
            count: names.count,
            mainIndex: mainIndex
        )

        return GeometryReader { geo in
            ZStack {
                if names.isEmpty {
                    // 空狀態
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("沒有顯示中的終端")
                            .foregroundStyle(.gray)
                    }
                } else {
                    ForEach(Array(zip(names.indices, slots)), id: \.0) { index, slot in
                        let name = names[index]
                        let terminal = terminals.first(where: { $0.name == name })!
                        let slotWidth = slot.width * geo.size.width - 4
                        let slotHeight = slot.height * geo.size.height - 4

                        VStack(spacing: 0) {
                            TerminalTitleBar(
                                name: name,
                                purpose: terminal.purpose,
                                status: "idle",
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
                                }
                            )
                            PreviewTerminalView(
                                name: name,
                                color: terminal.color,
                                isMain: index == mainIndex && workspace.layoutMode != .equal
                            )
                            .onTapGesture {
                                workspace.focusedTerminalName = name
                            }
                        }
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

    // MARK: - 最大化 View

    private func maximizedView(terminal: PreviewTerminal) -> some View {
        VStack(spacing: 0) {
            TerminalTitleBar(
                name: terminal.name,
                purpose: terminal.purpose,
                status: "idle",
                isFocused: true,
                isMaximized: true,
                availableModes: LayoutMode.allCases,
                onMaximize: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        workspace.toggleMaximize(terminal.name)
                    }
                },
                onClose: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        workspace.toggleMaximize(terminal.name)
                        closeTerminal(terminal.name)
                    }
                }
            )
            PreviewTerminalView(
                name: terminal.name,
                color: terminal.color,
                isMain: false
            )
        }
    }

    // MARK: - 資料

    private var normalTerminals: [PreviewTerminal] {
        let names = workspace.normalTerminalNames(from: terminals.map(\.name))
        return terminals.filter { names.contains($0.name) }
    }

    private var minimizedTerminals: [PreviewTerminal] {
        let names = workspace.minimizedTerminalNames(from: terminals.map(\.name))
        return terminals.filter { names.contains($0.name) }
    }

    // MARK: - 操作

    private func addTerminal() {
        let name = "Terminal-\(nextIndex)"
        let color = availableColors[(nextIndex - 1) % availableColors.count]
        let terminal = PreviewTerminal(name: name, purpose: "新終端", color: color)
        terminals.append(terminal)
        workspace.registerTerminal(name)
        nextIndex += 1
    }

    private func closeTerminal(_ name: String) {
        workspace.removeTerminal(name)
        terminals.removeAll { $0.name == name }
    }
}
