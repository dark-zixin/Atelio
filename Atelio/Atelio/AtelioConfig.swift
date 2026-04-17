import Foundation

/// Atelio 全域設定（從 ~/.atelio/config.json 讀取）
enum AtelioConfig {

    /// 內建預設 AI CLI 白名單
    private static let defaultAiClis: Set<String> = ["codex", "claude", "gemini", "aider"]

    /// 當前有效白名單（default union user 設定）
    private(set) static var aiCliWhitelist: Set<String> = defaultAiClis

    /// Config 檔案路徑
    private static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atelio")
            .appendingPathComponent("config.json")
    }

    // MARK: - Debug Log

    /// 共用 debug log：寫到 ~/.atelio/debug.log 與 NSLog
    /// 靜默失敗，不拋例外
    static func debugLog(_ event: String, _ data: [String: Any] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var parts = ["\(timestamp)", "event=\(event)"]
        for (key, value) in data.sorted(by: { $0.key < $1.key }) {
            let str = "\(value)".replacingOccurrences(of: "\n", with: "\\n")
            parts.append("\(key)=\(str)")
        }
        let line = parts.joined(separator: " ") + "\n"

        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".atelio")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("debug.log")

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }

        // 同時印到 Console
        NSLog("[Atelio] %@ %@", event, data.description)
    }

    /// App 啟動時呼叫：確保檔案存在 + 讀取合併
    static func load() {
        debugLog("config_load_start")
        writeDefaultIfMissing()
        mergeFromFile()
        debugLog("config_load_done", ["whitelist": aiCliWhitelist.sorted().joined(separator: ",")])
    }

    /// 如果 config 檔案不存在，建立一個含範例內容的檔案
    private static func writeDefaultIfMissing() {
        let path = configPath
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path.path) else {
            debugLog("config_already_exists", ["path": path.path])
            return
        }

        // 確保目錄存在
        try? fm.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let template = """
        {
          "//": "此處列出的 AI CLI 名稱會跟內建清單（codex, claude, gemini, aider）合併，啟用時自動注入 turn marker。一般 shell / REPL / vim 等不要加進來，會破壞指令執行。",
          "additional_ai_clis": []
        }

        """
        try? template.write(to: path, atomically: true, encoding: .utf8)
        debugLog("config_written", ["path": path.path])
    }

    /// 從 config 檔讀取 additional_ai_clis，union 進白名單
    /// 讀取失敗或格式錯誤 → log 並保持內建預設
    private static func mergeFromFile() {
        struct ConfigFile: Decodable {
            let additional_ai_clis: [String]?
        }

        guard let data = try? Data(contentsOf: configPath) else {
            NSLog("[AtelioConfig] 無法讀 config 檔，使用內建白名單")
            debugLog("config_read_fail")
            return
        }
        debugLog("config_file_read", ["size": data.count])

        guard let config = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            NSLog("[AtelioConfig] config 格式錯誤，使用內建白名單")
            debugLog("config_parse_fail")
            return
        }

        let userAdded = Set(config.additional_ai_clis ?? [])
        aiCliWhitelist = defaultAiClis.union(userAdded)
        debugLog("config_parse_ok", ["user_added": userAdded.count])
    }

    /// 判斷某個 command 是否該啟用 marker
    /// 規則：取第一個 token 的 basename，查白名單
    static func shouldEnableMarker(for command: String) -> Bool {
        debugLog("marker_check", ["command": command])
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            debugLog("marker_check_result", [
                "command": command,
                "basename": "",
                "whitelist_size": aiCliWhitelist.count,
                "matches": false
            ])
            return false
        }
        let firstToken = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        let basename = (firstToken as NSString).lastPathComponent
        let result = aiCliWhitelist.contains(basename)
        debugLog("marker_check_result", [
            "command": command,
            "basename": basename,
            "whitelist_size": aiCliWhitelist.count,
            "matches": result
        ])
        return result
    }
}
