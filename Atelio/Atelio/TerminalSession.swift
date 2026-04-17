import Foundation
import SwiftTerm
import AppKit
import AtelioShared

/// 單一終端 session，管理一個 PTY process 的生命週期
class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {

    let id = UUID()
    let name: String
    let purpose: String
    let createdAt: Date

    /// SwiftTerm 終端 view
    let terminalView: LocalProcessTerminalView

    /// Turn 完成偵測協調器
    let coordinator: TurnCoordinator

    /// Transcript 累積器
    let transcriptAccumulator: TranscriptAccumulator

    /// process 是否還在執行
    var isRunning = false

    /// 工作目錄
    let workingDirectory: String

    /// close 確認 key（busy 時產生，用於二次確認）
    private(set) var pendingCloseKey: String?

    /// 擁有者的 PPID（第一次 dispatch 時記錄，用於防止不同 AI 操作同一 session）
    var ownerPID: Int32?

    /// 是否啟用 turn marker 注入（根據 cmd 白名單判斷，init 時決定）
    let markerEnabled: Bool

    // MARK: - 初始化

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    init(name: String, purpose: String, directory: String, command: String) {
        AtelioConfig.debugLog("session_init_start", [
            "name": name,
            "command": command,
            "directory": directory
        ])
        self.name = name
        self.purpose = purpose
        self.createdAt = Date()
        self.workingDirectory = directory
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.transcriptAccumulator = TranscriptAccumulator()
        self.coordinator = TurnCoordinator(terminalView: terminalView, transcriptAccumulator: transcriptAccumulator)
        self.markerEnabled = AtelioConfig.shouldEnableMarker(for: command)
        AtelioConfig.debugLog("session_marker_enabled", [
            "name": name,
            "markerEnabled": self.markerEnabled
        ])

        super.init()

        terminalView.processDelegate = self

        // 啟動 process
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // SwiftTerm 的預設 PATH 只有 /bin:/usr/bin:/usr/ucb:/usr/local/bin，
        // 找不到 homebrew / nvm / ~/.local/bin 等位置的 AI CLI。
        // 覆蓋為 Atelio App process 的 PATH，讓子 process 能找到實際安裝的指令。
        if let parentPath = ProcessInfo.processInfo.environment["PATH"] {
            env.removeAll { $0.hasPrefix("PATH=") }
            env.append("PATH=\(parentPath)")
            AtelioConfig.debugLog("path_overridden", ["path": parentPath])
        } else {
            AtelioConfig.debugLog("path_not_overridden", [:])
        }
        env.append("CLAUDE_CODE_NO_FLICKER=1")
        env.append("ATELIO_SESSION=\(name)")
        env.append("ATELIO_SOCKET=/tmp/atelio.sock")

        if !directory.isEmpty {
            let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
            let argString = "[-c, cd '\(escapedDir)' && \(command)]"
            AtelioConfig.debugLog("session_about_to_startprocess", [
                "name": name,
                "exe": "/bin/zsh",
                "args": argString
            ])
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-c", "cd '\(escapedDir)' && \(command)"],
                environment: env
            )
        } else {
            let argString = "[-c, \(command)]"
            AtelioConfig.debugLog("session_about_to_startprocess", [
                "name": name,
                "exe": "/bin/zsh",
                "args": argString
            ])
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-c", command],
                environment: env
            )
        }
        AtelioConfig.debugLog("session_startprocess_called", ["name": name])
        isRunning = true
        AtelioConfig.debugLog("session_init_done", ["name": name])
    }

    // MARK: - 就緒等待

    /// 等待就緒（簡單輪詢畫面穩定 + process 存活，不走 coordinator）
    func waitForReady(timeout: Int = 5, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var lastHash = ""
        var stableSince: Date?

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { timer.cancel(); completion(false); return }
            let alive = self.terminalView.process?.running ?? false
            if !alive { self.isRunning = false; timer.cancel(); completion(false); return }

            let terminal = self.terminalView.getTerminal()
            var lines: [String] = []
            for row in 0..<terminal.rows {
                if let line = terminal.getLine(row: row) {
                    lines.append(line.translateToString(trimRight: true))
                }
            }
            let hash = "\(lines.joined(separator: "\n").hashValue)"
            if hash != lastHash {
                lastHash = hash
                stableSince = Date()
            } else if let start = stableSince, Date().timeIntervalSince(start) >= 2.0 {
                timer.cancel()
                completion(true)
                return
            }
            if Date() >= deadline { timer.cancel(); completion(false) }
        }
        timer.resume()
    }

    // MARK: - 指令派發（新 API）

    /// 開始 dispatch：送文字 + 啟動 turn，回傳 semaphore
    func startDispatch(text: String) -> DispatchSemaphore? {
        AtelioConfig.debugLog("dispatch_start", [
            "name": name,
            "text": text,
            "markerEnabled": markerEnabled
        ])
        guard isRunning else { return nil }
        guard coordinator.phase == .idle else { return nil }
        let sem = coordinator.beginTurn()
        let payload: String
        if markerEnabled, let marker = coordinator.currentMarker {
            payload = "\(marker)\n\(text)"
        } else {
            payload = text
        }
        // Bracketed paste mode 包裝：讓 AI CLI 把 input 當 paste 處理，
        // 避免 `!` 等字元觸發熱鍵（例如 Gemini 會把 `!` 當 shell mode trigger）
        let wrapped = "\u{001B}[200~\(payload)\u{001B}[201~"
        AtelioConfig.debugLog("dispatch_payload", [
            "name": name,
            "marker": (coordinator.currentMarker ?? "nil"),
            "payload": payload
        ])
        terminalView.send(txt: wrapped)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.terminalView.send(txt: "\r")
        }
        AtelioConfig.debugLog("dispatch_sent", ["name": name])
        return sem
    }

    /// 開始 wait：取得目前 turn 的 semaphore
    func startWait() -> DispatchSemaphore? {
        guard isRunning else { return nil }
        if coordinator.phase == .idle { return nil }
        return coordinator.waitSemaphore()
    }

    /// 讀取 output（內部核心邏輯）
    /// - applyMarker: true 時套用 marker 切片（dispatch/wait 用），false 時整頁（screen 用）
    private func readRaw(applyMarker: Bool) -> String {
        AtelioConfig.debugLog("read_raw", [
            "name": name,
            "applyMarker": applyMarker,
            "markerEnabled": markerEnabled
        ])
        let viewport = readTerminalViewport()
        let marker = (applyMarker && markerEnabled) ? coordinator.currentMarker : nil
        AtelioConfig.debugLog("read_marker_decided", [
            "name": name,
            "marker": (marker ?? "nil")
        ])
        // 只在 alt-screen 中才用 transcript，離開 alt-screen 後用 full buffer
        let inAltScreen = terminalView.getTerminal().isCurrentBufferAlternate
        let result: String
        if inAltScreen, let transcriptOutput = transcriptAccumulator.readTranscript(viewport: viewport) {
            result = truncateIfNeeded(TerminalDenoise.clean(transcriptOutput, marker: marker))
        } else {
            let raw = String(data: terminalView.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
            result = truncateIfNeeded(TerminalDenoise.clean(raw, marker: marker))
        }
        AtelioConfig.debugLog("read_done", [
            "name": name,
            "outputSize": result.count
        ])
        return result
    }

    /// dispatch/wait 用：套用 marker 切片（如果 session 啟用）
    func readOutput() -> String { readRaw(applyMarker: true) }

    /// screen 用：永遠整頁，不切片
    func readScreen() -> String { readRaw(applyMarker: false) }

    /// Session 狀態（用於 UI 顯示）
    enum Status: String {
        case busy
        case idle
        case unowned
        case exited
    }

    /// 取得目前 session 狀態（每次查詢時即時計算）
    var status: Status {
        if !isRunning { return .exited }
        if let owner = ownerPID, kill(owner, 0) != 0 {
            return .unowned
        }
        return coordinator.phase == .idle ? .idle : .busy
    }

    /// 取得 session 狀態資訊
    func sessionInfo() -> SessionInfo {
        let pid = terminalView.process?.shellPid ?? 0
        return SessionInfo(
            name: name,
            purpose: purpose,
            isRunning: isRunning,
            pid: pid != 0 ? pid : nil,
            workingDirectory: workingDirectory,
            createdAt: Self.dateFormatter.string(from: createdAt)
        )
    }

    /// 檢查 session 是否忙碌
    func checkBusy(completion: @escaping (Bool) -> Void) {
        completion(coordinator.phase != .idle)
    }

    /// 關閉 session（直接關閉，不檢查狀態）
    func forceClose() {
        coordinator.handleProcessExit()
        terminalView.process?.terminate()
        isRunning = false
        pendingCloseKey = nil
    }

    /// 產生 close 確認 key
    func generateCloseKey() -> String {
        let key = UUID().uuidString.prefix(8).lowercased()
        pendingCloseKey = String(key)
        return String(key)
    }

    /// 驗證 close 確認 key
    func validateCloseKey(_ key: String) -> Bool {
        guard let pending = pendingCloseKey, pending == key else { return false }
        pendingCloseKey = nil
        return true
    }

    // MARK: - 輸出

    /// 輸出大小上限（256KB）
    private let maxOutputBytes = 256 * 1024

    /// 讀取 viewport（目前可見畫面）
    private func readTerminalViewport() -> String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 截斷過大的輸出，保留尾端，切在 UTF-8 安全的行邊界
    private func truncateIfNeeded(_ text: String) -> String {
        let totalBytes = text.utf8.count
        guard totalBytes > maxOutputBytes else { return text }

        let utf8Data = Data(text.utf8)
        var start = utf8Data.count - maxOutputBytes
        while start < utf8Data.count && start > 0 && (utf8Data[start] & 0xC0) == 0x80 {
            start += 1
        }
        guard let tailString = String(data: utf8Data[start...], encoding: .utf8) else {
            let safeStart = min(start + 4, utf8Data.count)
            let tail = String(data: utf8Data[safeStart...], encoding: .utf8) ?? String(text.suffix(maxOutputBytes / 4))
            return "[截斷：原始 \(totalBytes) bytes]\n" + tail
        }
        var tail = tailString
        if let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }
        return "[截斷：原始 \(totalBytes) bytes，保留最後 \(tail.utf8.count) bytes]\n" + tail
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        AtelioConfig.debugLog("session_process_terminated", [
            "name": self.name,
            "exitCode": exitCode ?? -999
        ])
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            self?.coordinator.handleProcessExit()
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // MARK: - Hook 事件轉發

    func handleTurnStart() {
        coordinator.handleHookStart()
    }

    func handleTurnEnd() {
        coordinator.handleHookEnd()
    }
}
