import Foundation
import SwiftTerm

/// Turn 完成偵測的集中管理器
///
/// 持有 terminalView + transcriptAccumulator，統一 timer 驅動。
/// 每 tick：讀畫面 → hash → 追蹤穩定 → 判斷完成 → signal semaphore。
class TurnCoordinator {

    // MARK: - 型別

    enum TurnPhase { case idle, working, waitingApproval, draining }
    enum TurnCompletionReason { case hookTurnEnded, quietWindowMet, processExited, aborted, approvalNeeded }

    // MARK: - 公開狀態

    private(set) var phase: TurnPhase = .idle
    private(set) var hookSeen = false
    private(set) var completed = false
    private(set) var completionReason: TurnCompletionReason?

    // MARK: - 內部狀態

    private let terminalView: LocalProcessTerminalView
    private let transcriptAccumulator: TranscriptAccumulator
    /// session 名稱，只用於 log 標記（所有 session 的 turn 事件寫同一份 log，無名字不可分辨）
    private let sessionName: String

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

    init(terminalView: LocalProcessTerminalView, transcriptAccumulator: TranscriptAccumulator, sessionName: String) {
        self.terminalView = terminalView
        self.transcriptAccumulator = transcriptAccumulator
        self.sessionName = sessionName
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
        AtelioLog.trace("turn_begin", [
            "name": sessionName,
            "preHash": preDispatchHash.prefix(16),
            "marker": currentMarker ?? "none"
        ])
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
        AtelioLog.trace("turn_hook_start_received", ["name": sessionName, "phase": phase, "hookSeen": hookSeen])
        // 也接受 waitingApproval（與 handleHookEnd 已放寬的對稱）：handleApprovalNeeded 不要求
        // hookSeen 就會把 phase 推到 waitingApproval，若 turn_start 在 IPC 層 late delivery、晚於
        // approval_needed 抵達，這裡只認 .working 會把它丟掉、hookSeen 留 false，連帶後續 turn_end
        // 也被 handleHookEnd 的 hookSeen 條件擋掉，turn 永遠收不到完成訊號。語意維持
        // 「hookSeen = 本輪收過 turn_start」——phase 不動（仍由 approval 流程主導）、stableSince 不重置，
        // 只是允許 late delivery 在 approval 中間態補登記。
        guard phase == .working || phase == .waitingApproval else { return }
        hookSeen = true
        AtelioLog.trace("turn_hook_start_accepted", ["name": sessionName])
    }

    func handleHookEnd() {
        AtelioLog.trace("turn_hook_end_received", ["name": sessionName, "phase": phase, "hookSeen": hookSeen])
        // 也接受 waitingApproval：worker 跳過 approval（主 AI 已 send-keys 處理）後續跑完
        // 才送 turn_end，此時 phase 仍停在 waitingApproval，不能漏掉這個完成訊號。
        guard phase == .working || phase == .waitingApproval, hookSeen else { return }
        phase = .draining
        stableSince = Date()
        AtelioLog.trace("turn_hook_end_accepted", ["name": sessionName])
    }

    /// 收到 approval_needed hook 事件：worker 跳出授權選單、turn 沒結束
    /// （Stop / turn_end hook 不會觸發，畫面動畫又讓 quiet window 永不 met）。
    /// 把 phase 標記為 waitingApproval 並**即時喚醒所有等待中的 dispatch/wait waiter**，
    /// 讓主 AI 立刻拿到當前畫面（授權選單）去處理，不必空等到 timeout。
    ///
    /// 與 `complete` 的差異：**不結束 turn**——不停 timer、不設 completed、phase 不回 idle。
    /// 主 AI 看選單 → send-keys 處理 → 重新 wait，會接回同一個 turn 後續的完成偵測
    /// （worker 跑完送 turn_end → draining；或畫面穩定走 quiet window / 60s fallback 兜底）。
    /// 離開 approval 沒有對應 hook 事件（實測證實），所以這裡不追蹤離開、不維護長期狀態。
    func handleApprovalNeeded() {
        AtelioLog.trace("turn_approval_received", ["name": sessionName, "phase": phase, "hookSeen": hookSeen])
        // 只在 turn 進行中（working / 已在 waitingApproval 的同 turn 二次 approval）才處理；
        // idle / draining 視為過時事件忽略。
        guard phase == .working || phase == .waitingApproval else { return }
        phase = .waitingApproval
        completionReason = .approvalNeeded
        AtelioLog.ops("turn_approval_needed", ["name": sessionName])
        // 喚醒當前 waiter 但清空陣列（不結束 turn）：清空讓後續重新 wait 取得新的
        // semaphore，避免同一個 semaphore 被之後的事件（turn_end / 二次 approval）重複 signal。
        let sems = completionSemaphores
        completionSemaphores = []
        sems.forEach { $0.signal() }
    }

    func handleProcessExit() {
        complete(.processExited)
    }

    /// 強制結束目前 turn（reset 原語）：phase 回 idle、signal 所有 waiter。
    /// 用於 turn 卡住（取消 approval 後等 fallback、畫面無變化等）時的逃生門。
    func abortTurn() {
        guard phase != .idle else { return }
        AtelioLog.ops("turn_abort_requested", ["name": sessionName, "phase": phase])
        complete(.aborted)
    }

    /// 畫面最近一次變化距今的秒數（reset 穩定閘用）。
    /// timer 在所有非 idle phase（working / waitingApproval / draining）運行，idle 時數值凍結——
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
        case .working, .waitingApproval:
            // waitingApproval 與 working 共用完成偵測：
            // - approval 已被主 AI 處理、worker 續跑跑完 → 正常路徑是 turn_end → draining；
            //   走不到 hook 時這裡的 quiet window / 60s fallback 仍能收束（與一般 turn 一致）。
            // - 主 AI 遲遲不處理 approval → 同樣由 fallback 兜底，turn 不會永久卡在 waitingApproval。
            if !hookSeen {
                // 非 hook session：5 秒穩定 + 畫面有變
                if stableMs >= 5000 && lastHash != preDispatchHash {
                    complete(.quietWindowMet)
                }
            } else {
                // hook session + 沒收到 turn_end：60 秒 fallback
                if stableMs >= 60000 {
                    AtelioLog.ops("turn_fallback_triggered", ["name": sessionName])
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
        AtelioLog.trace("turn_complete", [
            "name": sessionName,
            "reason": reason,
            "prevPhase": phase,
            "hookSeen": hookSeen
        ])
        phase = .idle
        completed = true
        completionReason = reason
        stopTimer()
        let sems = completionSemaphores
        completionSemaphores = []
        sems.forEach { $0.signal() }
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

}
