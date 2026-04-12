import XCTest
import SwiftUI
import SnapshotTesting
@testable import Atelio

final class LayoutSnapshotTests: XCTestCase {

    // 預覽尺寸模擬螢幕 3/5 的寬度
    let previewSize = CGSize(width: 800, height: 500)

    // MARK: - 均分模式

    func testEqual_2terminals() {
        assertLayoutSnapshot(mode: .equal, names: ["Claude", "Codex"])
    }

    func testEqual_3terminals() {
        assertLayoutSnapshot(mode: .equal, names: ["Claude", "Codex", "Gemini"])
    }

    func testEqual_4terminals() {
        assertLayoutSnapshot(mode: .equal, names: ["Claude", "Codex", "Gemini", "Cursor"])
    }

    func testEqual_6terminals() {
        assertLayoutSnapshot(mode: .equal, names: ["T1", "T2", "T3", "T4", "T5", "T6"])
    }

    // MARK: - 上大下小模式

    func testTopMain_2terminals() {
        assertLayoutSnapshot(mode: .topMain, names: ["Claude", "Codex"])
    }

    func testTopMain_3terminals() {
        assertLayoutSnapshot(mode: .topMain, names: ["Claude", "Codex", "Gemini"])
    }

    func testTopMain_4terminals() {
        assertLayoutSnapshot(mode: .topMain, names: ["Claude", "Codex", "Gemini", "Cursor"])
    }

    func testTopMain_5terminals() {
        assertLayoutSnapshot(mode: .topMain, names: ["Claude", "Codex", "Gemini", "Cursor", "Aider"])
    }

    // MARK: - 左大右小模式

    func testLeftMain_2terminals() {
        assertLayoutSnapshot(mode: .leftMain, names: ["Claude", "Codex"])
    }

    func testLeftMain_3terminals() {
        assertLayoutSnapshot(mode: .leftMain, names: ["Claude", "Codex", "Gemini"])
    }

    func testLeftMain_4terminals() {
        assertLayoutSnapshot(mode: .leftMain, names: ["Claude", "Codex", "Gemini", "Cursor"])
    }

    // MARK: - 主位切換

    func testTopMain_3terminals_mainIndex1() {
        assertLayoutSnapshot(mode: .topMain, names: ["Claude", "Codex", "Gemini"], mainIndex: 1)
    }

    func testLeftMain_3terminals_mainIndex2() {
        assertLayoutSnapshot(mode: .leftMain, names: ["Claude", "Codex", "Gemini"], mainIndex: 2)
    }

    // MARK: - 邊界情況

    func testSingleTerminal() {
        assertLayoutSnapshot(mode: .equal, names: ["Claude"])
    }

    // MARK: - 輔助方法

    private func assertLayoutSnapshot(
        mode: LayoutMode,
        names: [String],
        mainIndex: Int = 0,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let view = LayoutPreviewView(
            mode: mode,
            terminalNames: names,
            mainIndex: mainIndex
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
