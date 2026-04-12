import XCTest
import SwiftUI
import SnapshotTesting
@testable import Atelio

final class MinimizedBarSnapshotTests: XCTestCase {

    let previewSize = CGSize(width: 800, height: 500)

    // MARK: - 底部縮小列

    func testMinimizedBar_twoTerminals() {
        let view = MinimizedBar(terminals: [
            MinimizedTerminalInfo(name: "Gemini", status: "idle"),
            MinimizedTerminalInfo(name: "Claude-2", status: "busy"),
        ])
        .frame(width: 600)
        .background(Color.black)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: CGSize(width: 600, height: 30))
        )
    }

    // MARK: - 完整畫面：layout + 底部列

    func testFullWorkspace_withMinimizedBar() {
        let view = VStack(spacing: 0) {
            // 上方：layout 區域（2 個正常終端）
            LayoutPreviewView(
                mode: .leftMain,
                terminalNames: ["Claude Code", "Codex Review"],
                mainIndex: 0,
                showTitleBar: true,
                focusedIndex: 0
            )

            // 底部：縮小列
            MinimizedBar(terminals: [
                MinimizedTerminalInfo(name: "Gemini", status: "idle"),
                MinimizedTerminalInfo(name: "Cursor", status: "busy"),
            ])
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .background(Color.black)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: previewSize)
        )
    }
}
