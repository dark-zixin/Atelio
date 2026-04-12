import SwiftUI
@testable import Atelio

/// Layout 預覽 View，用假終端色塊呈現 Layout 排版效果
struct LayoutPreviewView: View {
    let mode: LayoutMode
    let terminalNames: [String]
    let mainIndex: Int
    var showTitleBar: Bool = false
    var focusedIndex: Int = 0

    var body: some View {
        let slots = LayoutTemplate.generateSlots(
            mode: mode,
            count: terminalNames.count,
            mainIndex: mainIndex
        )

        GeometryReader { geo in
            ZStack {
                // 背景
                Color.black

                // 每個終端色塊（含 title bar）
                ForEach(Array(zip(terminalNames.indices, slots)), id: \.0) { index, slot in
                    let slotWidth = slot.width * geo.size.width - 4
                    let slotHeight = slot.height * geo.size.height - 4

                    VStack(spacing: 0) {
                        if showTitleBar {
                            TerminalTitleBar(
                                name: terminalNames[index],
                                purpose: "用途描述",
                                isFocused: index == focusedIndex,
                                isMaximized: false,
                                availableModes: LayoutMode.allCases
                            )
                        }

                        FakeTerminalView(
                            name: showTitleBar ? "" : terminalNames[index],
                            color: terminalColors[index % terminalColors.count],
                            isMain: index == mainIndex && mode != .equal
                        )
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
