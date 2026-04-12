import Foundation
import SwiftTerm
import AppKit

/// 繼承 LocalProcessTerminalView，攔截 PTY 輸出資料
///
/// 完成偵測：畫面內容 hash 穩定 3 秒即判定完成。
/// dataReceived 只作為「有新資料」的觸發信號，每 200ms 才讀一次畫面做 hash 比對。
class CaptureTerminalView: LocalProcessTerminalView {

    /// 是否正在擷取
    private(set) var isCapturing = false

    /// 畫面穩定門檻（秒）
    var stabilityThreshold: TimeInterval = 2.0

    /// 完成回調
    private var completionHandler: ((String, Bool) -> Void)?

    /// 超時 timer
    private var timeoutTimer: DispatchWorkItem?

    /// dispatch 前的畫面快照
    private var preDispatchSnapshot = ""

    /// 是否已收到任何新資料
    private var hasReceivedData = false

    /// 是否要求畫面必須變化才觸發完成（dispatch=true, wait=false）
    private var requireScreenChange = true

    // MARK: - 畫面 hash 偵測

    /// 畫面 hash 檢查 timer（每 200ms）
    private var screenCheckTimer: DispatchSourceTimer?

    /// 上次畫面 hash
    private var lastScreenHash = ""

    /// 畫面穩定開始時間（hash 不再變化的時間點）
    private var stableStartTime: Date?

    // MARK: - Debug log

    private var logHandle: FileHandle?
    private var lastDataTime = Date()
    private var captureStartTime = Date()

    func enableDebugLog(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
        writeLog("event,gap_ms,bytes,screen_changed,stable_ms,note")
    }

    private func writeLog(_ line: String) {
        guard let handle = logHandle else { return }
        let elapsed = Date().timeIntervalSince(captureStartTime) * 1000
        let ts = {
            let d = Date()
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: d)
        }()
        if let data = "\(ts),\(String(format: "%.0f", elapsed)),\(line)\n".data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    // MARK: - 擷取控制

    func startCapture(timeout: Int, requireScreenChange: Bool = true, completion: @escaping (String, Bool) -> Void) {
        isCapturing = true
        hasReceivedData = false
        self.requireScreenChange = requireScreenChange
        completionHandler = completion
        captureStartTime = Date()
        if requireScreenChange {
            preDispatchSnapshot = readTerminalBuffer()
        } else {
            preDispatchSnapshot = ""
        }
        lastScreenHash = stableHash(readTerminalBuffer())
        stableStartTime = nil

        writeLog("START,0,0,false,0,timeout=\(timeout) requireChange=\(requireScreenChange)")

        // 啟動畫面 hash 檢查 timer（每 200ms）
        startScreenCheckTimer()

        // 設定超時
        let timeoutWork = DispatchWorkItem { [weak self] in
            let stableMs = self?.currentStableMs() ?? 0
            self?.writeLog("TIMEOUT,0,0,false,\(stableMs),超時")
            self?.finishCapture(completed: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWork)
        timeoutTimer = timeoutWork
    }

    func stopCapture() {
        isCapturing = false
        stopScreenCheckTimer()
        timeoutTimer?.cancel()
        timeoutTimer = nil
        completionHandler = nil
    }

    // MARK: - PTY 資料攔截（只記錄，不讀畫面）

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let now = Date()
        let gap = now.timeIntervalSince(lastDataTime) * 1000
        lastDataTime = now

        super.dataReceived(slice: slice)

        if isCapturing {
            hasReceivedData = true
            writeLog("PTY,\(Int(gap)),\(slice.count),,,")
        } else if gap > 2000 {
            // 非 capture 期間只記錄大 gap（idle 基線）
            writeLog("PTY_IDLE,\(Int(gap)),\(slice.count),,,")
        }
    }

    // MARK: - 畫面 hash 定期檢查

    private func startScreenCheckTimer() {
        stopScreenCheckTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.checkScreenHash()
        }
        timer.resume()
        screenCheckTimer = timer
    }

    private func stopScreenCheckTimer() {
        screenCheckTimer?.cancel()
        screenCheckTimer = nil
    }

    private func checkScreenHash() {
        guard isCapturing else { return }
        guard hasReceivedData || !requireScreenChange else { return }

        let screen = readTerminalBuffer()
        let hash = stableHash(screen)
        let changed = hash != lastScreenHash

        if changed {
            // 畫面有變化 → 重置穩定計時
            lastScreenHash = hash
            stableStartTime = Date()
            // 記錄最後一行非空內容（幫助判斷狀態）
            let lastLine = screen.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            let summary = String((lastLine ?? "").prefix(60)).replacingOccurrences(of: ",", with: ";")
            writeLog("SCREEN,0,0,true,0,\(summary)")
        } else if let stableStart = stableStartTime {
            // 畫面沒變 → 計算穩定時間
            let stableMs = Date().timeIntervalSince(stableStart) * 1000

            // 確認畫面跟 dispatch 前不同（避免指令未送達就觸發）
            let differentFromPre = hash != stableHash(preDispatchSnapshot)

            if stableMs >= stabilityThreshold * 1000 && differentFromPre {
                writeLog("COMPLETE,0,0,false,\(Int(stableMs)),畫面穩定\(String(format: "%.1f", stableMs/1000))秒")
                finishCapture(completed: true)
            }
        } else {
            // 首次檢查，還沒有 stableStartTime
            stableStartTime = Date()
        }
    }

    private func currentStableMs() -> Int {
        guard let start = stableStartTime else { return 0 }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - 完成

    private func finishCapture(completed: Bool) {
        guard isCapturing else { return }
        isCapturing = false
        stopScreenCheckTimer()
        timeoutTimer?.cancel()
        timeoutTimer = nil

        writeLog("FINISH,0,0,false,0,completed=\(completed)")

        let currentScreen = readTerminalBuffer()
        let handler = completionHandler
        completionHandler = nil
        handler?(currentScreen, completed)
    }

    // MARK: - Terminal buffer 讀取

    func readTerminalBuffer() -> String {
        let terminal = getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        return lines.joined(separator: "\n")
    }

    func readFullBuffer() -> String {
        let terminal = getTerminal()
        let data = terminal.getBufferAsData()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func stableHash(_ text: String) -> String {
        let cleaned = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        return "\(cleaned.hashValue)"
    }
}
