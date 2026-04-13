import XCTest
import SwiftUI
import SnapshotTesting
@testable import Atelio

final class TitleBarSnapshotTests: XCTestCase {

    let previewSize = CGSize(width: 800, height: 500)

    // MARK: - Title Bar 整合測試

    func testTopMain_3terminals_withTitleBar() {
        let view = LayoutPreviewView(
            mode: .topMain,
            terminalNames: ["Claude Code", "Codex Review", "Gemini"],
            mainIndex: 0,
            showTitleBar: true,
            focusedIndex: 0
        )
        .frame(width: previewSize.width, height: previewSize.height)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: previewSize)
        )
    }

    func testLeftMain_4terminals_withTitleBar_focused2() {
        let view = LayoutPreviewView(
            mode: .leftMain,
            terminalNames: ["Claude", "Codex", "Gemini", "Cursor"],
            mainIndex: 0,
            showTitleBar: true,
            focusedIndex: 2
        )
        .frame(width: previewSize.width, height: previewSize.height)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: previewSize)
        )
    }

    // MARK: - 單獨 Title Bar

    func testTitleBar_focused() {
        let view = TerminalTitleBar(
            name: "Claude Code",
            purpose: "主力開發",
            status: "busy",
            isFocused: true,
            isMaximized: false,
            availableModes: LayoutMode.allCases
        )
        .frame(width: 400)
        .background(Color.black)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: CGSize(width: 400, height: 30))
        )
    }

    func testTitleBar_unfocused() {
        let view = TerminalTitleBar(
            name: "Codex Review",
            purpose: "code review",
            status: "idle",
            isFocused: false,
            isMaximized: false,
            availableModes: LayoutMode.allCases
        )
        .frame(width: 400)
        .background(Color.black)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: CGSize(width: 400, height: 30))
        )
    }
}
