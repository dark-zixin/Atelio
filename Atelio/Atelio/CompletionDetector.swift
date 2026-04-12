import Foundation
import SwiftTerm

/// 偵測終端指令是否執行完畢
///
/// 兩種偵測模式：
/// 1. Marker 模式：buffer 中出現指定的 marker 字串即判定完成（dispatch 使用）
/// 2. Prompt 模式：靜默 + prompt pattern 判定完成（fallback）
class CompletionDetector {

    // MARK: - 設定

    /// 靜默門檻（秒），buffer 無變化超過此時間才檢查 prompt
    var silenceThreshold: TimeInterval = 3.0

    /// Prompt 正則表達式，符合時判定指令已完成
    var promptPattern = "[$#%>]\\s*$"

    /// 完成 marker（設定後啟用 marker 模式）
    var completionMarker: String?

    // MARK: - 狀態

    private var timer: DispatchSourceTimer?
    private var lastSnapshot = ""
    private var lastChangeTime = Date()
    private var startTime = Date()
    private var timeoutSeconds: Int = 60
    private weak var terminalView: LocalProcessTerminalView?
    private var completion: ((String, Bool) -> Void)?

    // MARK: - 公開方法

    /// 開始偵測指令完成
    func start(
        terminalView: LocalProcessTerminalView,
        timeout: Int,
        completion: @escaping (String, Bool) -> Void
    ) {
        self.terminalView = terminalView
        self.timeoutSeconds = timeout
        self.completion = completion
        self.startTime = Date()
        self.lastChangeTime = Date()
        self.lastSnapshot = readVisibleBuffer()

        // 啟動輪詢 timer（每 500ms 檢查一次）
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    /// 停止偵測
    func stop() {
        timer?.cancel()
        timer = nil
        completion = nil
    }

    // MARK: - 內部邏輯

    private func tick() {
        guard terminalView != nil else {
            stop()
            return
        }

        // 檢查超時
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= Double(timeoutSeconds) {
            let output = readVisibleBuffer()
            completion?(output, false)
            stop()
            return
        }

        let current = readVisibleBuffer()

        // Marker 模式：只要 buffer 裡出現 marker 就判定完成
        if let marker = completionMarker, current.contains(marker) {
            completion?(current, true)
            stop()
            return
        }

        // Prompt 模式：靜默 + prompt pattern
        if completionMarker == nil {
            if current != lastSnapshot {
                lastSnapshot = current
                lastChangeTime = Date()
                return
            }

            let silence = Date().timeIntervalSince(lastChangeTime)
            guard silence >= silenceThreshold else { return }

            let lastLine = lastNonEmptyLine()
            guard matchesPrompt(lastLine) else { return }

            completion?(current, true)
            stop()
        } else {
            // Marker 模式下仍需追蹤變化（用於超時判斷）
            if current != lastSnapshot {
                lastSnapshot = current
                lastChangeTime = Date()
            }
        }
    }

    /// 使用公開 API 讀取可見 buffer 內容
    private func readVisibleBuffer() -> String {
        guard let terminalView = terminalView else { return "" }
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 取得最後一行非空內容
    private func lastNonEmptyLine() -> String {
        guard let terminalView = terminalView else { return "" }
        let terminal = terminalView.getTerminal()
        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
            if !text.isEmpty {
                return text
            }
        }
        return ""
    }

    /// 檢查文字是否符合 prompt pattern
    private func matchesPrompt(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: promptPattern) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
