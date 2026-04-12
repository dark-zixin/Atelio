import XCTest
import SwiftUI
import SnapshotTesting
@testable import Atelio

final class WorkspaceSnapshotTests: XCTestCase {

    let previewSize = CGSize(width: 800, height: 500)

    let sampleTerminals: [TerminalPreviewInfo] = [
        TerminalPreviewInfo(name: "Claude Code", purpose: "主力開發", status: "busy"),
        TerminalPreviewInfo(name: "Codex Review", purpose: "code review", status: "idle"),
        TerminalPreviewInfo(name: "Gemini", purpose: "文件生成", status: "idle"),
        TerminalPreviewInfo(name: "Cursor", purpose: "測試", status: "busy"),
    ]

    // MARK: - 正常狀態

    func testWorkspace_4terminals_topMain() {
        let workspace = WorkspaceState()
        workspace.layoutMode = .topMain
        workspace.mainTerminalName = "Claude Code"
        workspace.focusedTerminalName = "Claude Code"
        for t in sampleTerminals { workspace.registerTerminal(t.name) }

        assertWorkspaceSnapshot(workspace: workspace, terminals: sampleTerminals)
    }

    func testWorkspace_4terminals_equal_focusedGemini() {
        let workspace = WorkspaceState()
        workspace.layoutMode = .equal
        workspace.focusedTerminalName = "Gemini"
        for t in sampleTerminals { workspace.registerTerminal(t.name) }

        assertWorkspaceSnapshot(workspace: workspace, terminals: sampleTerminals)
    }

    // MARK: - 有最小化

    func testWorkspace_2normal_2minimized() {
        let workspace = WorkspaceState()
        workspace.layoutMode = .leftMain
        workspace.mainTerminalName = "Claude Code"
        workspace.focusedTerminalName = "Claude Code"
        for t in sampleTerminals { workspace.registerTerminal(t.name) }
        workspace.minimize("Gemini")
        workspace.minimize("Cursor")

        assertWorkspaceSnapshot(workspace: workspace, terminals: sampleTerminals)
    }

    // MARK: - 最大化

    func testWorkspace_maximized() {
        let workspace = WorkspaceState()
        workspace.layoutMode = .topMain
        workspace.mainTerminalName = "Claude Code"
        for t in sampleTerminals { workspace.registerTerminal(t.name) }
        workspace.toggleMaximize("Codex Review")

        assertWorkspaceSnapshot(workspace: workspace, terminals: sampleTerminals)
    }

    // MARK: - 輔助

    private func assertWorkspaceSnapshot(
        workspace: WorkspaceState,
        terminals: [TerminalPreviewInfo],
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let view = WorkspacePreviewView(
            workspace: workspace,
            allTerminals: terminals
        )
        .frame(width: previewSize.width, height: previewSize.height)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: previewSize),
            file: file,
            testName: testName,
            line: line
        )
    }
}
