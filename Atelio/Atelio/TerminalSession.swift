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

    /// 字體變更通知 observer token（用於 deinit 移除）
    private var fontObserver: NSObjectProtocol?

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

        super.init()

        terminalView.processDelegate = self

        // 套用目前全域字體大小（SwiftTerm setter 內部會 resetFont + 重算 cell）
        terminalView.font = Self.makeFont(size: AtelioConfig.fontSize)

        // 訂閱字體大小變更廣播：收到後切到 main queue 套用
        fontObserver = NotificationCenter.default.addObserver(
            forName: .atelioFontSizeChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.terminalView.font = Self.makeFont(size: AtelioConfig.fontSize)
            }
        }

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
        env.append("ATELIO_SOCKET=\(AtelioPaths.socketPath)")

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

    deinit {
        // 移除字體變更 observer，避免 observer 持有失效 session
        if let token = fontObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 字體

    /// 產生等寬字體：優先 Menlo，失敗 fallback 到系統 monospaced
    private static func makeFont(size: CGFloat) -> NSFont {
        return NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

    /// 讀取當前 foreground process 的 argv 並掃描白名單；命中回傳 AI CLI 名稱，否則 nil
    /// 失敗時分辨原因寫 debug log（排查偶發不切片時有用）
    private func currentForegroundAiCli() -> String? {
        guard let fd = terminalView.process?.childfd, fd >= 0 else {
            AtelioConfig.debugLog("dispatch_peek_fail", ["name": name, "reason": "no_childfd"])
            return nil
        }
        let pgrp = tcgetpgrp(fd)
        guard pgrp > 0 else {
            AtelioConfig.debugLog("dispatch_peek_fail", ["name": name, "reason": "tcgetpgrp_fail", "errno": errno])
            return nil
        }
        guard let argv = ProcessInspector.argv(for: pgrp) else {
            AtelioConfig.debugLog("dispatch_peek_fail", ["name": name, "reason": "argv_unavailable", "pgrp": pgrp])
            return nil
        }
        guard !argv.isEmpty else {
            AtelioConfig.debugLog("dispatch_peek_fail", ["name": name, "reason": "empty_argv", "pgrp": pgrp])
            return nil
        }
        return AtelioConfig.matchAiCli(argv: argv)
    }

    /// 開始 dispatch：送文字 + 啟動 turn，回傳 semaphore
    func startDispatch(text: String) -> DispatchSemaphore? {
        guard isRunning else { return nil }
        guard coordinator.phase == .idle else { return nil }

        // Runtime 動態判斷：peek foreground argv，決定此次是否注入 marker
        let aiCliHit = currentForegroundAiCli()
        AtelioConfig.debugLog("dispatch_argv_check", [
            "name": name,
            "text": text,
            "hit": aiCliHit ?? "MISS"
        ])

        let sem = coordinator.beginTurn(withMarker: aiCliHit != nil)
        let payload: String
        if let marker = coordinator.currentMarker {
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

    /// 送 raw keystroke bytes 到 PTY，不包 bracketed paste、不補 \r、不動 TurnCoordinator。
    /// 用於操作 AI CLI 的 TUI 互動（例如 approval prompt）。
    /// - Parameters:
    ///   - bytes: 已翻譯完成的 raw bytes（由 `translateKey` 產生）
    ///   - originalKey: 使用者輸入的原始 key name（用於 log）
    func sendRaw(bytes: String, originalKey: String) {
        guard isRunning else { return }
        let hex = bytes.utf8.map { String(format: "%02X", $0) }.joined(separator: " ")
        AtelioConfig.debugLog("send_keys", [
            "name": name,
            "key": originalKey,
            "hex": hex
        ])
        terminalView.send(txt: bytes)
    }

    /// 將 key name 翻譯為要送進 PTY 的 bytes（考慮 session 當下的 TUI 狀態）。
    /// 方向鍵會依 `Terminal.applicationCursor`（DECCKM）送 normal `\e[A` 或 application `\eOA` sequence。
    /// 其他 key 委派到 static `translateKey(_:)`。
    func translateKey(_ key: String) -> String? {
        let lower = key.lowercased()
        if let arrow = Self.arrowLetter(for: lower) {
            let appMode = terminalView.getTerminal().applicationCursor
            let intro = appMode ? "\u{001B}O" : "\u{001B}["
            return "\(intro)\(arrow)"
        }
        return Self.translateKey(key)
    }

    /// 將 key name 翻譯為 PTY bytes（不需要 session state 的部分）。大小寫不敏感。
    ///
    /// 支援的 key name：
    ///   - `enter` / `return`        → 0x0D
    ///   - `esc` / `escape`          → 0x1B
    ///   - `tab`                     → 0x09
    ///   - `space`                   → 0x20
    ///   - `bspace` / `backspace`    → 0x7F
    ///   - `c-<letter>`              → Ctrl-letter（0x01~0x1A，例 c-c=0x03）
    ///   - 任意單字元（`key.count == 1`）→ 原字元
    ///
    /// 方向鍵（up/down/left/right）需要 session state（applicationCursor），由 instance `translateKey(_:)` 處理。
    /// 不認得的多字元 key 回 nil（由呼叫端回 invalid_request）。
    public static func translateKey(_ key: String) -> String? {
        // 單字元優先，不做 lowercase（保留 'Y' vs 'y' 的語意）
        if key.count == 1 {
            return key
        }

        let lower = key.lowercased()
        switch lower {
        case "enter", "return":     return "\u{000D}"
        case "esc", "escape":       return "\u{001B}"
        case "tab":                 return "\u{0009}"
        case "space":               return "\u{0020}"
        case "bspace", "backspace": return "\u{007F}"
        default: break
        }

        // Ctrl-<letter>: c-a ~ c-z
        if lower.hasPrefix("c-") && lower.count == 3,
           let last = lower.last,
           let ascii = last.asciiValue,
           ascii >= 0x61, ascii <= 0x7A {
            return String(UnicodeScalar(ascii & 0x1F))
        }

        return nil
    }

    private static func arrowLetter(for lower: String) -> String? {
        switch lower {
        case "up":    return "A"
        case "down":  return "B"
        case "right": return "C"
        case "left":  return "D"
        default: return nil
        }
    }

    /// 開始 wait：取得目前 turn 的 semaphore
    func startWait() -> DispatchSemaphore? {
        guard isRunning else { return nil }
        if coordinator.phase == .idle { return nil }
        return coordinator.waitSemaphore()
    }

    /// 讀取 output（內部核心邏輯）
    /// - applyMarker: true 時套用 marker 切片（dispatch/wait 用），false 時整頁（screen 用）
    ///   實際切片與否取決於 `coordinator.currentMarker` 是否有值（該輪 dispatch 有注入 marker）
    private func readRaw(applyMarker: Bool) -> String {
        AtelioConfig.debugLog("read_raw", [
            "name": name,
            "applyMarker": applyMarker,
            "currentMarker": coordinator.currentMarker ?? "nil"
        ])
        let viewport = readTerminalViewport()
        let marker = applyMarker ? coordinator.currentMarker : nil
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

    /// dispatch/wait 用：是否真正切片取決於 `coordinator.currentMarker` 是否有值
    /// （per-dispatch 動態判斷：AI CLI session 注入 marker，shell 為 nil → pass-through 整頁）
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
