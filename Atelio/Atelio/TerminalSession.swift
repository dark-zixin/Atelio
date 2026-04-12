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

    /// SwiftTerm 終端 view（使用 CaptureTerminalView 攔截輸出）
    let terminalView: CaptureTerminalView

    /// process 是否還在執行
    var isRunning = false

    /// 工作目錄
    let workingDirectory: String

    /// close 確認 key（busy 時產生，用於二次確認）
    private(set) var pendingCloseKey: String?

    // MARK: - 初始化

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    init(name: String, purpose: String, directory: String, command: String) {
        self.name = name
        self.purpose = purpose
        self.createdAt = Date()
        self.workingDirectory = directory
        self.terminalView = CaptureTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        super.init()

        terminalView.processDelegate = self
        terminalView.enableDebugLog(path: "/tmp/atelio_debug_\(name).csv")

        // 啟動 process
        // 統一用 zsh -c 解析 command（支援帶參數、管線、複合指令）
        // directory 用單引號 escape（路徑可能有空格）
        // 不加 exec（會破壞複合指令語義）
        if !directory.isEmpty {
            let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-c", "cd '\(escapedDir)' && \(command)"]
            )
        } else {
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-c", command]
            )
        }
        isRunning = true
    }

    // MARK: - 就緒等待

    /// 等待就緒（畫面穩定 + process 存活）
    func waitForReady(timeout: Int = 5, completion: @escaping (Bool) -> Void) {
        terminalView.startCapture(timeout: timeout, requireScreenChange: false) { [weak self] _, completed in
            // 確認 process 仍然存活
            let alive = self?.terminalView.process?.running ?? false
            if !alive {
                self?.isRunning = false
            }
            completion(completed && alive)
        }
    }

    // MARK: - 指令派發

    /// 送出文字到終端並等待完成
    ///
    /// 事件驅動偵測：CaptureTerminalView 在 dataReceived 中即時檢查 prompt pattern，
    /// 偵測到 prompt 後等 0.5 秒確認 → 回傳擷取的完整輸出。
    func dispatch(text: String, timeout: Int, completion: @escaping (String, Bool) -> Void) {
        guard isRunning else {
            completion("", false)
            return
        }

        // 記錄 dispatch 前的 full buffer（用於 snapshot diff）
        let preBuffer = terminalView.readFullBuffer()

        // 開始擷取 + 完成偵測
        terminalView.startCapture(timeout: timeout) { [weak self] _, completed in
            guard let self = self else { return }
            let postBuffer = self.terminalView.readFullBuffer()
            let output = self.truncateIfNeeded(self.extractNewContent(pre: preBuffer, post: postBuffer))
            completion(output, completed)
        }

        // 先送文字，稍後再送 Enter（\r），避免 TUI 把整段當成 paste 處理
        terminalView.send(txt: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.terminalView.send(txt: "\r")
        }
    }

    /// 讀取目前終端可見畫面內容
    func readScreen() -> String {
        return terminalView.readTerminalBuffer()
    }

    /// 不送文字，只等待畫面穩定
    ///
    /// 用於 dispatch 返回半完成結果後，AI 判斷需要繼續等待的情境。
    func wait(timeout: Int, completion: @escaping (String, Bool) -> Void) {
        guard isRunning else {
            completion("", false)
            return
        }

        terminalView.startCapture(timeout: timeout, requireScreenChange: false) { [weak self] _, completed in
            guard let self = self else { return }
            let fullBuffer = self.truncateIfNeeded(self.terminalView.readFullBuffer())
            completion(fullBuffer, completed)
        }
        // 不送任何文字
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

    /// 檢查 session 是否忙碌（畫面正在變化）
    func checkBusy(completion: @escaping (Bool) -> Void) {
        let snapshot = terminalView.readTerminalBuffer()
        // 2 秒後再讀一次，比較畫面是否有變化
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self = self else { completion(false); return }
            let current = self.terminalView.readTerminalBuffer()
            completion(current != snapshot)
        }
    }

    /// 關閉 session（直接關閉，不檢查狀態）
    func forceClose() {
        terminalView.stopCapture()
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

    // MARK: - 輸出擷取（snapshot diff）

    /// 用共同前綴 diff 提取新增內容
    ///
    /// 找 pre 和 post buffer 的最長共同前綴，前綴之後就是新內容。
    /// 如果找不到可靠重疊，退回整個 post buffer（寧多勿少）。
    private func extractNewContent(pre: String, post: String) -> String {
        let preLines = pre.components(separatedBy: "\n")
        let postLines = post.components(separatedBy: "\n")

        // 找最長共同前綴（逐行比對）
        var commonEnd = 0
        let minCount = min(preLines.count, postLines.count)
        for i in 0..<minCount {
            if preLines[i] == postLines[i] {
                commonEnd = i + 1
            } else {
                break
            }
        }

        // 新增內容 = 共同前綴之後的部分
        var newLines = Array(postLines.suffix(from: commonEnd))

        // 如果完全沒有共同前綴（clear 或 TUI 重繪），退回整個 post
        if commonEnd == 0 && !pre.isEmpty {
            return post
        }

        // 移除尾部空行
        while newLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            newLines.removeLast()
        }

        return newLines.joined(separator: "\n")
    }

    /// 輸出大小上限（256KB）
    private let maxOutputBytes = 256 * 1024

    /// 截斷過大的輸出，保留尾端，切在 UTF-8 安全的行邊界
    private func truncateIfNeeded(_ text: String) -> String {
        let totalBytes = text.utf8.count
        guard totalBytes > maxOutputBytes else { return text }

        // 從尾端取 maxOutputBytes，用 Data 轉換確保 UTF-8 安全
        let utf8Data = Data(text.utf8)
        var start = utf8Data.count - maxOutputBytes
        // 往前退到 UTF-8 字元邊界（UTF-8 continuation byte 開頭是 10xxxxxx）
        while start < utf8Data.count && start > 0 && (utf8Data[start] & 0xC0) == 0x80 {
            start += 1
        }
        guard let tailString = String(data: utf8Data[start...], encoding: .utf8) else {
            // 最壞情況：多切一些確保能轉成 String
            let safeStart = min(start + 4, utf8Data.count)
            var tail = String(data: utf8Data[safeStart...], encoding: .utf8) ?? String(text.suffix(maxOutputBytes / 4))
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
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
