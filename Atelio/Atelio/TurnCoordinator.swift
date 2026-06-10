import Foundation
import SwiftTerm
import AtelioShared

/// Turn 完成偵測的集中管理器
///
/// 持有 terminalView + transcriptAccumulator，統一 timer 驅動。
/// 每 tick：讀畫面 → hash → 追蹤穩定 → 判斷完成 → signal semaphore。
class TurnCoordinator {

    // MARK: - 型別

    enum TurnPhase { case idle, working, draining }
    enum TurnCompletionReason { case hookTurnEnded, quietWindowMet, processExited, aborted }

    // MARK: - 公開狀態

    private(set) var phase: TurnPhase = .idle
    private(set) var hookSeen = false
    private(set) var completed = false
    private(set) var completionReason: TurnCompletionReason?

    // MARK: - 內部狀態

    private let terminalView: LocalProcessTerminalView
    private let transcriptAccumulator: TranscriptAccumulator

    private var preDispatchHash = ""
    private var lastHash = ""
    private var stableSince = Date()
    private var timer: DispatchSourceTimer?
    private var timerIntervalMs = 200
    /// 等待本輪完成的所有 waiter（dispatch 一個 + 可能並行的多個 wait）。
    /// complete 時全部 signal——覆寫單一欄位會讓先到的 waiter 空等到 timeout。
    private var completionSemaphores: [DispatchSemaphore] = []
    private var wasInAltScreen = false
    private var turnCounter: Int = 0
    private(set) var currentMarker: String?


    // MARK: - 初始化

    init(terminalView: LocalProcessTerminalView, transcriptAccumulator: TranscriptAccumulator) {
        self.terminalView = terminalView
        self.transcriptAccumulator = transcriptAccumulator
    }

    // MARK: - Turn 生命週期

    /// 開始新 turn，回傳 semaphore 給呼叫端等待
    /// - withMarker: 非 AI CLI session（shell 等）傳 false，`currentMarker` 會保持 nil
    func beginTurn(withMarker: Bool = true) -> DispatchSemaphore {
        stopTimer()
        turnCounter += 1
        // Marker 隨機成分（8 hex）每 turn 重生，切片找「第一次出現」才不會命中畫面上
        // 殘留的舊 marker 文字：
        // - 跨 session：resume 類 worker（codex resume / claude --continue）會重繪舊對話
        //   （含舊 marker），而 turnCounter 每個實例從 1 重起，固定格式必同名碰撞
        // - 同 session：固定 nonce 在 turn 1 後即露出於畫面、counter 可預測，轉發含
        //   marker 的文字等場景可偽造出未來 marker；每 turn 重生使其無法預測
        let nonce = String(UUID().uuidString.prefix(8))
        currentMarker = withMarker ? "<!-- ATELIO-\(nonce)-T-\(turnCounter) -->" : nil
        phase = .working
        hookSeen = false
        completed = false
        completionReason = nil
        transcriptAccumulator.reset()
        if lastHash.isEmpty {
            lastHash = stableHash(readTerminalBuffer())
        }
        preDispatchHash = lastHash
        stableSince = Date()
        let sem = DispatchSemaphore(value: 0)
        completionSemaphores = [sem]
        startTimer(intervalMs: 200)
        let markerDesc = currentMarker ?? "none"
        appendLog("beginTurn preHash=\(preDispatchHash.prefix(16)) marker=\(markerDesc)")
        return sem
    }

    /// 取得目前 turn 的 semaphore（給 wait 使用）
    /// 加入 waiter 清單而非覆寫：先前的 waiter（如阻塞中的 dispatch）仍會在完成時被 signal
    func waitSemaphore() -> DispatchSemaphore? {
        guard phase != .idle else { return nil }
        let sem = DispatchSemaphore(value: 0)
        completionSemaphores.append(sem)
        return sem
    }

    // MARK: - Hook 事件

    func handleHookStart() {
        appendLog("hookStart_received phase=\(phase) hookSeen=\(hookSeen)")
        guard phase == .working else { return }
        hookSeen = true
        appendLog("hookStart_accepted")
    }

    func handleHookEnd() {
        appendLog("hookEnd_received phase=\(phase) hookSeen=\(hookSeen)")
        guard phase == .working, hookSeen else { return }
        phase = .draining
        stableSince = Date()
        appendLog("hookEnd_accepted → draining")
    }

    func handleProcessExit() {
        complete(.processExited)
    }

    /// 強制結束目前 turn（reset 原語）：phase 回 idle、signal 所有 waiter。
    /// 用於 turn 卡住（取消 approval 後等 fallback、畫面無變化等）時的逃生門。
    func abortTurn() {
        guard phase != .idle else { return }
        appendLog("abortTurn_requested")
        complete(.aborted)
    }

    /// 畫面最近一次變化距今的秒數（reset 穩定閘用）。
    /// timer 只在 working/draining 期間運行，idle 時數值凍結——
    /// 呼叫端（handleReset）僅在 phase 非 idle 時讀取，此時 tick 每 100-200ms 更新中。
    var secondsSinceScreenChange: TimeInterval {
        Date().timeIntervalSince(stableSince)
    }

    // MARK: - Timer

    private func startTimer(intervalMs: Int) {
        stopTimer()
        timerIntervalMs = intervalMs
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func rescheduleTimer(_ intervalMs: Int) {
        guard intervalMs != timerIntervalMs else { return }
        startTimer(intervalMs: intervalMs)
    }

    // MARK: - Tick

    private func tick() {
        // 1. 讀畫面
        let screen = readTerminalBuffer()
        let hash = stableHash(screen)
        let altScreen = terminalView.getTerminal().isCurrentBufferAlternate

        // 2. alt-screen 轉換
        if !wasInAltScreen && altScreen { transcriptAccumulator.handleAltScreenEnter() }
        if wasInAltScreen && !altScreen { transcriptAccumulator.handleAltScreenExit() }
        wasInAltScreen = altScreen

        // 3. 調 timer 頻率
        let targetInterval = altScreen ? 100 : 200
        if targetInterval != timerIntervalMs { rescheduleTimer(targetInterval) }

        // 4. hash 追蹤
        let changed = hash != lastHash
        if changed {
            lastHash = hash
            stableSince = Date()
            // TUI + 變了 → transcript 累積
            if altScreen {
                let terminal = terminalView.getTerminal()
                let size = (cols: terminal.cols, rows: terminal.rows)
                transcriptAccumulator.accumulate(screen: screen, terminalSize: size)
            }
        }
        let stableMs = Date().timeIntervalSince(stableSince) * 1000

        // 5. 判斷完成
        switch phase {
        case .working:
            if !hookSeen {
                // 非 hook session：5 秒穩定 + 畫面有變
                if stableMs >= 5000 && lastHash != preDispatchHash {
                    complete(.quietWindowMet)
                }
            } else {
                // hook session + 沒收到 turn_end：60 秒 fallback
                if stableMs >= 60000 {
                    appendLog("fallback_triggered")
                    complete(.quietWindowMet)
                }
            }
        case .draining:
            // drain：1 秒穩定
            if stableMs >= 1000 {
                complete(.hookTurnEnded)
            }
        case .idle:
            break
        }
    }

    // MARK: - 完成

    private func complete(_ reason: TurnCompletionReason) {
        guard phase != .idle else { return }
        appendLog("complete reason=\(reason) prevPhase=\(phase) hookSeen=\(hookSeen)")
        phase = .idle
        completed = true
        completionReason = reason
        stopTimer()
        let sems = completionSemaphores
        completionSemaphores = []
        sems.forEach { $0.signal() }
        appendLog("complete_\(reason)")
    }

    // MARK: - Terminal buffer 讀取

    private func readTerminalBuffer() -> String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func stableHash(_ text: String) -> String {
        let cleaned = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        return "\(cleaned.hashValue)"
    }

    // MARK: - Hook log

    private static let hookLogFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func appendLog(_ event: String) {
        // 目錄 `~/.atelio/` 由 `AtelioPaths.ensureRoot()` 在 App 啟動早期建立，
        // 本函式相信目錄已存在。
        let logFile = AtelioPaths.hookLogPath
        let line = "\(Self.hookLogFormatter.string(from: Date())) event=\(event) phase=\(phase)\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}
