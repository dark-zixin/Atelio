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

    // MARK: - TUI Transcript 累積

    /// 已離開 viewport 的行（ring buffer）
    private var transcript: [String] = []
    private let maxTranscriptLines = 3000

    /// 上一幀的所有行（用於 overlap 比對）
    private var prevFrameRows: [String]?

    /// 上一幀的終端尺寸（用於偵測 resize）
    private var prevFrameSize: (cols: Int, rows: Int)?

    /// 上次是否在 alt-screen 中（用於偵測離開 alt-screen）
    private var wasInAltScreen = false

    /// transcript 累積用的獨立 timer（100ms，只在 alt-screen 時運行）
    private var transcriptTimer: DispatchSourceTimer?

    /// transcript timer 用的 hash（獨立於 screenCheckTimer 的 hash）
    private var lastTranscriptHash = ""

    /// 是否在 alt-screen 中
    private var isInAltScreen: Bool {
        let terminal = getTerminal()
        return terminal.isCurrentBufferAlternate
    }

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
        stopTranscriptTimer()
    }

    /// 啟動 transcript 累積 timer（100ms，只在 alt-screen 時運行）
    private func startTranscriptTimer() {
        guard transcriptTimer == nil else { return }
        lastTranscriptHash = ""
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.checkTranscript()
        }
        timer.resume()
        transcriptTimer = timer
    }

    /// 停止 transcript 累積 timer
    private func stopTranscriptTimer() {
        transcriptTimer?.cancel()
        transcriptTimer = nil
    }

    /// transcript 累積的定期檢查（100ms）
    private func checkTranscript() {
        let currentlyInAltScreen = isInAltScreen

        // 離開 alt-screen → 清空 transcript + 停止 timer
        if !currentlyInAltScreen {
            resetTranscript()
            stopTranscriptTimer()
            return
        }

        // 讀畫面，hash 沒變就跳過
        let screen = readTerminalBuffer()
        let hash = stableHash(screen)
        if hash == lastTranscriptHash { return }
        lastTranscriptHash = hash

        accumulateTranscript(screen: screen)
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
        // 如果有等待中的 handler，回傳空結果讓呼叫端的 semaphore 被 signal
        // （避免 forceClose 時 IPC 呼叫端卡到 timeout）
        let handler = completionHandler
        completionHandler = nil
        handler?("", false)
    }

    // MARK: - PTY 資料攔截

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let now = Date()
        let gap = now.timeIntervalSince(lastDataTime) * 1000
        lastDataTime = now

        super.dataReceived(slice: slice)

        if isCapturing {
            hasReceivedData = true
            writeLog("PTY,\(Int(gap)),\(slice.count),,,")
        }
    }

    // MARK: - 畫面 hash 定期檢查（統一 timer）

    private func checkScreenHash() {
        let screen = readTerminalBuffer()
        let hash = stableHash(screen)
        let changed = hash != lastScreenHash
        let currentlyInAltScreen = isInAltScreen

        // 偵測進入 alt-screen → 啟動 transcript timer
        if !wasInAltScreen && currentlyInAltScreen {
            resetTranscript()
            startTranscriptTimer()
        }
        wasInAltScreen = currentlyInAltScreen

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

        let currentScreen = readFullBufferWithTranscript()
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

    // MARK: - TUI Transcript 累積邏輯

    /// 正規化行內容用於比對（null bytes 替換為空格，去除頭尾空白）
    private func normalizeLine(_ line: String) -> String {
        // null bytes 和控制字元替換為空格（不是移除，避免改變字間距）
        let cleaned = line.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" {
                return " "  // null bytes 和控制字元 → 空格
            }
            return Character(scalar)
        }
        return String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 在 alt-screen 畫面變化時，比對前後幀並累積被推掉的行
    private func accumulateTranscript(screen: String) {
        let currRows = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let terminal = getTerminal()
        let currentSize = (cols: terminal.cols, rows: terminal.rows)

        guard let prev = prevFrameRows else {
            // 第一幀 → 記錄，不做其他事
            prevFrameRows = currRows
            prevFrameSize = currentSize
            writeLog("TRANSCRIPT,0,0,,,第一幀 rows=\(currRows.count)")
            return
        }

        // 偵測 resize
        if let prevSize = prevFrameSize,
           (prevSize.cols != currentSize.cols || prevSize.rows != currentSize.rows) {
            writeLog("TRANSCRIPT,0,0,,,resize \(prevSize.cols)x\(prevSize.rows) → \(currentSize.cols)x\(currentSize.rows)")
            appendToTranscript(prev)
            appendGapMarker()
            prevFrameRows = currRows
            prevFrameSize = currentSize
            return
        }

        // Fast-path：比對前 3 行，如果相同 → 頂部沒變 → 跳過
        let prevTopLines = prev.prefix(3).map { normalizeLine($0) }
        let currTopLines = currRows.prefix(3).map { normalizeLine($0) }
        if prevTopLines == currTopLines {
            prevFrameRows = currRows
            prevFrameSize = currentSize
            return
        }

        writeLog("TRANSCRIPT,0,0,,,頂部變了 prev[0]=[\(normalizeLine(prev[0]).prefix(40))] curr[0]=[\(normalizeLine(currRows[0]).prefix(40))]")

        // 頂部變了 → 做 suffix-prefix overlap
        let (departed, overlapFound) = findDepartedLines(prev: prev, curr: currRows)

        writeLog("TRANSCRIPT,0,0,,,overlap=\(overlapFound) departed=\(departed.count)行 transcript=\(transcript.count)行")

        if !departed.isEmpty {
            let meaningful = departed.filter { !normalizeLine($0).isEmpty }
            if !meaningful.isEmpty {
                appendToTranscript(departed)
            }

            if !overlapFound {
                appendGapMarker()
            }
        }

        prevFrameRows = currRows
        prevFrameSize = currentSize
    }

    /// 讀取完整內容（含 transcript 累積的歷史）
    /// 在 alt-screen 時回傳 transcript + viewport（做 overlap join 去重）
    /// 非 alt-screen 時直接回傳 getBufferAsData()（原行為）
    func readFullBufferWithTranscript() -> String {
        guard isInAltScreen, !transcript.isEmpty else {
            return readFullBuffer()  // 非 alt-screen 或沒有 transcript → 原行為
        }

        let viewport = readTerminalBuffer()
        let viewportLines = viewport.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // overlap join：找 transcript 尾端和 viewport 頭部的重疊
        let joined = overlapJoin(transcript: transcript, viewport: viewportLines)
        return joined.joined(separator: "\n")
    }

    /// suffix-prefix overlap：找 curr 的頂部在 prev 中的位置
    /// 回傳 prev 中「在 overlap 之前」的行（即被推掉的行）
    ///
    /// 演算法：從 curr 的前幾行出發，在 prev 中找到匹配位置。
    /// curr 的頂部就是「推動後的新起點」，在 prev 中找到這個起點之前的行就是被推掉的。
    private func findDepartedLines(prev: [String], curr: [String]) -> (departed: [String], overlapFound: Bool) {
        // 從 curr 的前 5 行中，找一個非空行作為 anchor
        for currAnchorIdx in 0..<min(curr.count, 5) {
            let currNorm = normalizeLine(curr[currAnchorIdx])
            if currNorm.isEmpty { continue }

            // 在 prev 的全部範圍中找這行
            for prevIdx in 0..<prev.count {
                let prevNorm = normalizeLine(prev[prevIdx])
                if prevNorm != currNorm { continue }

                // 找到候選匹配點，驗證連續匹配
                var matchCount = 0
                var nonEmptyMatchCount = 0
                var pi = prevIdx
                var ci = currAnchorIdx
                while pi < prev.count && ci < curr.count {
                    let p = normalizeLine(prev[pi])
                    let c = normalizeLine(curr[ci])
                    if p == c {
                        matchCount += 1
                        if !p.isEmpty { nonEmptyMatchCount += 1 }
                    } else {
                        break
                    }
                    pi += 1
                    ci += 1
                }

                if matchCount >= 5 && nonEmptyMatchCount >= 3 {
                    let departedEnd = max(0, prevIdx - currAnchorIdx)
                    let departed = Array(prev[0..<departedEnd])
                    writeLog("OVERLAP,0,0,,,anchor=[\(currNorm.prefix(30))] prevIdx=\(prevIdx) currAnchorIdx=\(currAnchorIdx) match=\(matchCount) departed=\(departedEnd)")
                    return (departed, true)
                } else {
                    writeLog("OVERLAP,0,0,,,嘗試 anchor=[\(currNorm.prefix(30))] prevIdx=\(prevIdx) match=\(matchCount)/nonEmpty=\(nonEmptyMatchCount) 不夠")
                }
            }
        }

        // 失敗時把前幾行寫到獨立的 debug 檔
        let debugPath = "/tmp/atelio_overlap_debug_\(Date().timeIntervalSince1970).txt"
        var debugContent = "=== OVERLAP FAIL ===\n"
        debugContent += "prev: \(prev.count) 行 | curr: \(curr.count) 行\n\n"
        debugContent += "--- curr 前 10 行 ---\n"
        for i in 0..<min(10, curr.count) {
            let norm = normalizeLine(curr[i])
            let hex = curr[i].prefix(30).unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
            debugContent += "[\(i)] len=\(curr[i].count) normLen=\(norm.count)\n"
            debugContent += "  raw: \(curr[i].prefix(80))\n"
            debugContent += "  norm: \(norm.prefix(80))\n"
            debugContent += "  hex: \(hex)\n\n"
        }
        debugContent += "--- prev 前 10 行 ---\n"
        for i in 0..<min(10, prev.count) {
            let norm = normalizeLine(prev[i])
            let hex = prev[i].prefix(30).unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
            debugContent += "[\(i)] len=\(prev[i].count) normLen=\(norm.count)\n"
            debugContent += "  raw: \(prev[i].prefix(80))\n"
            debugContent += "  norm: \(norm.prefix(80))\n"
            debugContent += "  hex: \(hex)\n\n"
        }
        try? debugContent.write(toFile: debugPath, atomically: true, encoding: .utf8)
        writeLog("OVERLAP-FAIL 詳見 \(debugPath)")

        return (prev, false)
    }

    /// transcript + viewport 的 overlap join（去重合併）
    ///
    /// 從 viewport 的前幾行出發，在 transcript 的尾端找匹配位置。
    /// 找到後，transcript 在匹配點之前的部分 + 完整 viewport = 去重後的結果。
    private func overlapJoin(transcript: [String], viewport: [String]) -> [String] {
        guard !transcript.isEmpty, !viewport.isEmpty else {
            return transcript + viewport
        }

        // 從 viewport 的前 5 行找一個 anchor
        for vAnchorIdx in 0..<min(viewport.count, 5) {
            let vLine = normalizeLine(viewport[vAnchorIdx])
            if vLine.isEmpty { continue }

            // 在 transcript 的後半段找這行
            let searchStart = max(0, transcript.count - 100)
            for tIdx in searchStart..<transcript.count {
                let tLine = normalizeLine(transcript[tIdx])
                if tLine != vLine { continue }

                // 驗證連續匹配
                var matchCount = 0
                var nonEmptyMatchCount = 0
                var ti = tIdx
                var vi = vAnchorIdx
                while ti < transcript.count && vi < viewport.count {
                    let t = normalizeLine(transcript[ti])
                    let v = normalizeLine(viewport[vi])
                    if t == v {
                        matchCount += 1
                        if !t.isEmpty { nonEmptyMatchCount += 1 }
                    } else {
                        break
                    }
                    ti += 1
                    vi += 1
                }

                if matchCount >= 5 && nonEmptyMatchCount >= 3 {
                    // transcript 在匹配點之前的部分 + 完整 viewport
                    let cutPoint = max(0, tIdx - vAnchorIdx)
                    return Array(transcript[0..<cutPoint]) + viewport
                }
            }
        }

        // 沒找到重疊 → 直接接起來
        return transcript + viewport
    }

    /// 把行存入 transcript（ring buffer，超過上限刪最舊的）
    private func appendToTranscript(_ lines: [String]) {
        transcript.append(contentsOf: lines)
        if transcript.count > maxTranscriptLines {
            let overflow = transcript.count - maxTranscriptLines
            transcript.removeFirst(overflow)
            // 如果最前面不是 truncated marker，插入一個
            if !transcript.isEmpty && !transcript[0].hasPrefix("[truncated") {
                transcript.insert("[truncated: 歷史紀錄超過 \(maxTranscriptLines) 行上限]", at: 0)
            }
        }
    }

    /// 插入 gap marker
    private func appendGapMarker() {
        // 避免連續插多個 gap
        if let last = transcript.last, last.contains("[snapshot gap]") {
            return
        }
        transcript.append("... [snapshot gap] ...")
    }

    /// 重置 transcript 狀態（離開 alt-screen 或 session 關閉時）
    func resetTranscript() {
        transcript.removeAll()
        prevFrameRows = nil
        prevFrameSize = nil
    }

    // MARK: - Resize 控制

    override func setFrameSize(_ newSize: NSSize) {
        // 攔截極小中間尺寸（SwiftUI layout 過渡期會產生極小 frame）
        if newSize.width < 20 || newSize.height < 20 {
            return
        }

        super.setFrameSize(newSize)
    }
}
