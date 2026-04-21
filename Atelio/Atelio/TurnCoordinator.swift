import Foundation
import SwiftTerm

/// Turn 完成偵測的集中管理器
///
/// 持有 terminalView + transcriptAccumulator，統一 timer 驅動。
/// 每 tick：讀畫面 → hash → 追蹤穩定 → 判斷完成 → signal semaphore。
class TurnCoordinator {

    // MARK: - 型別

    enum TurnPhase { case idle, working, draining }
    enum TurnCompletionReason { case hookTurnEnded, quietWindowMet, processExited }

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
    private var completionSemaphore: DispatchSemaphore?
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
        currentMarker = withMarker ? "<!-- ATELIO-T-\(turnCounter) -->" : nil
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
        completionSemaphore = sem
        startTimer(intervalMs: 200)
        let markerDesc = currentMarker ?? "none"
        appendLog("beginTurn preHash=\(preDispatchHash.prefix(16)) marker=\(markerDesc)")
        return sem
    }

    /// 取得目前 turn 的 semaphore（給 wait 使用）
    func waitSemaphore() -> DispatchSemaphore? {
        guard phase != .idle else { return nil }
        let sem = DispatchSemaphore(value: 0)
        completionSemaphore = sem
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
        let sem = completionSemaphore
        completionSemaphore = nil
        sem?.signal()
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
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".atelio")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("hook.log")
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
