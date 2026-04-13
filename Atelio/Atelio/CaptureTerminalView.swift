import Foundation
import SwiftTerm
import AppKit

/// 繼承 LocalProcessTerminalView，攔截 PTY 輸出資料
///
/// 完成偵測：畫面內容 hash 穩定 5 秒即判定完成。
/// 統一 timer 在 session 存活期間持續運行，同時負責 idle 狀態監控和 capture 完成偵測。
class CaptureTerminalView: LocalProcessTerminalView {

    /// 是否正在擷取
    private(set) var isCapturing = false

    /// 畫面是否處於靜止狀態（穩定超過 stabilityThreshold 秒）
    private(set) var isScreenIdle = true

    /// 畫面穩定門檻（秒）
    var stabilityThreshold: TimeInterval = 5.0

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

    // MARK: - 畫面 hash 偵測（統一 timer）

    /// 畫面 hash 檢查 timer（每 200ms，session 存活期間持續運行）
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

    /// 啟動統一 timer（session 建立後呼叫一次）
    func startIdleMonitor() {
        guard screenCheckTimer == nil else { return }
        lastScreenHash = stableHash(readTerminalBuffer())
        stableStartTime = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.checkScreenHash()
        }
        timer.resume()
        screenCheckTimer = timer
    }

    /// 停止統一 timer（session 關閉時呼叫）
    func stopIdleMonitor() {
        screenCheckTimer?.cancel()
        screenCheckTimer = nil
    }

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

        // 統一 timer 已在持續運行，不需要額外啟動

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
        timeoutTimer?.cancel()
        timeoutTimer = nil
        completionHandler = nil
    }

    // MARK: - PTY 資料攔截 + resize 敏感偵測

    /// resize 後短時間內收到大量 PTY 輸出 → 標記為 resizeSensitive
    private(set) var resizeSensitive = false

    /// 最近一次 resize 的時間
    private var lastResizeTime: Date?

    /// resize 後累積的 PTY bytes
    private var postResizePtyBytes = 0

    /// 偵測門檻：resize 後 200ms 內收到 > 1024 bytes 判定為 heavy redraw
    private let resizeSensitiveThreshold = 1024
    private let resizeSensitiveWindow: TimeInterval = 0.2

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let now = Date()
        let gap = now.timeIntervalSince(lastDataTime) * 1000
        lastDataTime = now

        // 偵測 resize 後的大量 PTY 輸出
        if let resizeTime = lastResizeTime, now.timeIntervalSince(resizeTime) < resizeSensitiveWindow {
            postResizePtyBytes += slice.count
            if postResizePtyBytes > resizeSensitiveThreshold && !resizeSensitive {
                resizeSensitive = true
            }
        }

        super.dataReceived(slice: slice)

        if isCapturing {
            hasReceivedData = true
            writeLog("PTY,\(Int(gap)),\(slice.count),,,")
        } else if gap > 2000 {
            writeLog("PTY_IDLE,\(Int(gap)),\(slice.count),,,")
        }
    }

    // MARK: - 畫面 hash 定期檢查（統一 timer）

    private func checkScreenHash() {
        let screen = readTerminalBuffer()
        let hash = stableHash(screen)
        let changed = hash != lastScreenHash

        if changed {
            // 畫面有變化 → 重置穩定計時，標記為非 idle
            lastScreenHash = hash
            stableStartTime = Date()
            isScreenIdle = false

            if isCapturing {
                let lastLine = screen.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                let summary = String((lastLine ?? "").prefix(60)).replacingOccurrences(of: ",", with: ";")
                writeLog("SCREEN,0,0,true,0,\(summary)")
            }
        } else if let stableStart = stableStartTime {
            // 畫面沒變 → 計算穩定時間
            let stableMs = Date().timeIntervalSince(stableStart) * 1000

            // 更新 idle 狀態
            if stableMs >= stabilityThreshold * 1000 {
                isScreenIdle = true
            }

            // capture 完成偵測
            if isCapturing {
                guard hasReceivedData || !requireScreenChange else { return }
                let differentFromPre = hash != stableHash(preDispatchSnapshot)
                if stableMs >= stabilityThreshold * 1000 && differentFromPre {
                    writeLog("COMPLETE,0,0,false,\(Int(stableMs)),畫面穩定\(String(format: "%.1f", stableMs/1000))秒")
                    finishCapture(completed: true)
                }
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
        timeoutTimer?.cancel()
        timeoutTimer = nil

        writeLog("FINISH,0,0,false,0,completed=\(completed)")

        let currentScreen = readFullBuffer()
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

    // MARK: - Resize 控制

    override func setFrameSize(_ newSize: NSSize) {
        // 攔截極小中間尺寸（SwiftUI layout 過渡期會產生極小 frame）
        if newSize.width < 20 || newSize.height < 20 {
            return
        }

        lastResizeTime = Date()
        postResizePtyBytes = 0
        super.setFrameSize(newSize)
    }
}
