import XCTest
@testable import Atelio

/// TerminalDenoise.clean(_:marker:) 的 marker 切片行為測試
///
/// 只測試 marker 相關行為（L2 切片），不重複驗證其他 pipeline 步驟。
/// 測試輸入刻意避開 block elements（U+2500/2580-259F）與 prompt 指示符（❯/›），
/// 以確保 marker 切片的影響可以被獨立觀察。
final class TerminalDenoiseTests: XCTestCase {

    // MARK: - 基本 pass-through 行為

    /// marker 為 nil → 原文（僅經 pipeline 其他步驟，marker 切片不作用）
    func testMarkerNil_ReturnsOriginal() {
        let input = "hello\nworld"
        let output = TerminalDenoise.clean(input, marker: nil)
        XCTAssertEqual(output, "hello\nworld")
    }

    /// marker 為空字串 → 原文
    func testMarkerEmpty_ReturnsOriginal() {
        let input = "hello\nworld"
        let output = TerminalDenoise.clean(input, marker: "")
        XCTAssertEqual(output, "hello\nworld")
    }

    /// marker 不在 text 裡 → 原文 pass through
    func testMarkerNotFound_ReturnsOriginal() {
        let input = "hello\nworld"
        let output = TerminalDenoise.clean(input, marker: "<!-- ATELIO-T-42 -->")
        XCTAssertEqual(output, "hello\nworld")
    }

    // MARK: - 切片行為

    /// marker 獨占一整行（行中只有 marker），切片後只保留後面的行
    func testMarkerAtMiddleLine_ReturnsAfterMarker() {
        let marker = "<!-- ATELIO-T-1 -->"
        let input = [
            "line1",
            "line2",
            marker,
            "line4",
            "line5"
        ].joined(separator: "\n")

        let output = TerminalDenoise.clean(input, marker: marker)
        XCTAssertEqual(output, "line4\nline5")
    }

    /// marker 在某行行尾（真實場景：user prompt 後綴 marker）
    /// → 從下一行開始回傳
    func testMarkerAtLineEnd_ReturnsNextLinesOnly() {
        let marker = "<!-- ATELIO-T-2 -->"
        let input = [
            "some preamble",
            "user prompt \(marker)",
            "ai response line 1",
            "ai response line 2"
        ].joined(separator: "\n")

        let output = TerminalDenoise.clean(input, marker: marker)
        XCTAssertEqual(output, "ai response line 1\nai response line 2")
    }

    /// marker 在文字中出現兩次 → 以第一次出現的位置切
    func testMarkerFoundMultipleTimes_UsesFirstOccurrence() {
        let marker = "<!-- ATELIO-T-3 -->"
        let input = [
            "echo \(marker)",
            "content A",
            "ref \(marker)",
            "content B"
        ].joined(separator: "\n")

        let output = TerminalDenoise.clean(input, marker: marker)
        // 第一次出現在第 1 行行尾，切片後從第 2 行開始
        XCTAssertEqual(output, "content A\nref \(marker)\ncontent B")
    }

    /// marker 在最後一行（後面沒有 newline）→ 空字串
    func testMarkerOnLastLine_ReturnsEmpty() {
        let marker = "<!-- ATELIO-T-4 -->"
        let input = "prev line\ntail with \(marker)"

        let output = TerminalDenoise.clean(input, marker: marker)
        XCTAssertEqual(output, "")
    }

    // MARK: - 與其他 pipeline 步驟協同

    /// 驗證 marker 切片與 rtrim、空行壓縮的共同作用
    /// pipeline 順序：L0 → L0.5 → L1（空行壓縮）→ L1.4 → L2（marker 切片）
    /// → 空行在被切前已被壓縮
    func testMarkerWithPipelineSideEffects() {
        let marker = "<!-- ATELIO-T-5 -->"
        // 故意塞多個連續空行 + 行尾空白
        let input = [
            "preamble line   ",           // 行尾空白應被 rtrim
            "",
            "",
            "user prompt \(marker)",      // 含 marker 的行
            "",
            "",
            "response line A   ",         // 行尾空白應被 rtrim
            "",
            "response line B"
        ].joined(separator: "\n")

        let output = TerminalDenoise.clean(input, marker: marker)
        // marker 之後：原本 response 之間有 2 個空行，壓縮後為 1 個
        // 行尾空白被 rtrim
        XCTAssertEqual(output, "\nresponse line A\n\nresponse line B")
    }
}
