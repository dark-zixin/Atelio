import SwiftUI
@testable import Atelio

/// 完整的 Workspace 預覽，整合 WorkspaceState、Layout、TitleBar、MinimizedBar
///
/// 用於 snapshot 測試和未來 Computer Use 互動測試。
struct WorkspacePreviewView: View {
    @State var workspace: WorkspaceState
    let allTerminals: [TerminalPreviewInfo]

    var body: some View {
        let normalNames = workspace.normalTerminalNames(from: allTerminals.map(\.name))
        let minimizedNames = workspace.minimizedTerminalNames(from: allTerminals.map(\.name))
        let minimizedInfos = allTerminals
            .filter { minimizedNames.contains($0.name) }
            .map { MinimizedTerminalInfo(name: $0.name, status: $0.status) }

        VStack(spacing: 0) {
            // 最大化模式：只顯示一個終端
            if let maxName = workspace.maximizedTerminalName,
               let terminal = allTerminals.first(where: { $0.name == maxName }) {
                let index = allTerminals.firstIndex(where: { $0.name == maxName }) ?? 0
                VStack(spacing: 0) {
                    TerminalTitleBar(
                        name: terminal.name,
                        purpose: terminal.purpose,
                        status: "idle",
                        isFocused: true,
                        isMaximized: true,
                        availableModes: LayoutMode.allCases,
                        onMaximize: { workspace.toggleMaximize(terminal.name) }
                    )
                    FakeTerminalView(
                        name: "",
                        color: terminalColors[index % terminalColors.count],
                        isMain: false
                    )
                }
            } else {
                // 正常模式：layout 排版
                layoutContent(normalNames: normalNames)
            }

            // 底部縮小列（有縮小的終端時才顯示）
            if !minimizedInfos.isEmpty {
                MinimizedBar(terminals: minimizedInfos) { name in
                    workspace.restore(name)
                }
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func layoutContent(normalNames: [String]) -> some View {
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
                ForEach(Array(zip(normalNames.indices, slots)), id: \.0) { index, slot in
                    let name = normalNames[index]
                    let terminal = allTerminals.first(where: { $0.name == name })!
                    let globalIndex = allTerminals.firstIndex(where: { $0.name == name }) ?? 0
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
                                workspace.selectLayout(mode: mode, mainTerminal: name)
                            },
                            onMinimize: { workspace.minimize(name) },
                            onMaximize: { workspace.toggleMaximize(name) },
                            onClose: { workspace.removeTerminal(name) }
                        )
                        FakeTerminalView(
                            name: "",
                            color: terminalColors[globalIndex % terminalColors.count],
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

/// 測試用的終端資訊
struct TerminalPreviewInfo {
    let name: String
    let purpose: String
    let status: String  // "idle" / "busy"
}
