import Foundation
import CoreGraphics

/// Atelio 全域設定（從 ~/.atelio/config.json 讀取）
enum AtelioConfig {

    /// 內建預設 AI CLI 白名單
    private static let defaultAiClis: Set<String> = ["codex", "claude", "gemini", "aider"]

    /// 當前有效白名單（default union user 設定）
    private(set) static var aiCliWhitelist: Set<String> = defaultAiClis

    // MARK: - 字體大小

    /// 字體大小預設值（pt）
    static let fontSizeDefault: CGFloat = 13

    /// 字體大小下限（pt）
    static let fontSizeMin: CGFloat = 8

    /// 字體大小上限（pt）
    static let fontSizeMax: CGFloat = 36

    /// 目前字體大小（pt）
    /// 寫入請走 `setFontSize(_:)` / `resetFontSize()`，以確保同步持久化。
    private(set) static var fontSize: CGFloat = fontSizeDefault

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
        debugLog("config_load_done", [
            "whitelist": aiCliWhitelist.sorted().joined(separator: ","),
            "fontSize": fontSize
        ])
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
          "additional_ai_clis": [],
          "font_size": 13
        }

        """
        try? template.write(to: path, atomically: true, encoding: .utf8)
        debugLog("config_written", ["path": path.path])
    }

    /// 從 config 檔讀取 additional_ai_clis 與 font_size
    ///
    /// 採逐欄位容錯：單一欄位型別錯誤不影響其他欄位；
    /// 只有整個 JSON 無法 parse 成 object 時才全回預設。
    /// 讀取失敗或格式錯誤 → log 並保持內建預設。
    private static func mergeFromFile() {
        guard let data = try? Data(contentsOf: configPath) else {
            NSLog("[AtelioConfig] 無法讀 config 檔，使用內建白名單")
            debugLog("config_read_fail")
            return
        }
        debugLog("config_file_read", ["size": data.count])

        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            NSLog("[AtelioConfig] config 非 JSON object，保留內建預設")
            debugLog("config_parse_fail")
            return
        }

        // 白名單：只有型別對時才套用，錯的話保留預設並 log
        if let arr = dict["additional_ai_clis"] as? [String] {
            let userAdded = Set(arr)
            aiCliWhitelist = defaultAiClis.union(userAdded)
            debugLog("config_whitelist_loaded", ["user_added": userAdded.count])
        } else if dict["additional_ai_clis"] != nil {
            debugLog("config_whitelist_type_mismatch", [:])
        }

        // 字體大小：接受 Double 或 Int；型別錯時保留預設並 log
        if let raw = dict["font_size"] as? Double {
            let clamped = clampFontSize(CGFloat(raw))
            fontSize = clamped
            debugLog("config_font_size_loaded", ["raw": raw, "clamped": clamped])
        } else if let raw = dict["font_size"] as? Int {
            let clamped = clampFontSize(CGFloat(raw))
            fontSize = clamped
            debugLog("config_font_size_loaded_int", ["raw": raw, "clamped": clamped])
        } else if dict["font_size"] != nil {
            debugLog("config_font_size_type_mismatch", [:])
        }

        debugLog("config_parse_ok", [:])
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

    // MARK: - 字體大小操作

    /// 將字體大小 clamp 在合法範圍
    private static func clampFontSize(_ value: CGFloat) -> CGFloat {
        return min(max(value, fontSizeMin), fontSizeMax)
    }

    /// 設定字體大小：clamp → 檢查是否變動 → 更新 in-memory → 寫檔 → 廣播
    ///
    /// 執行緒約定：必須從 main thread 呼叫（與 `DispatchActivity` 同 pattern）。
    /// 呼叫點目前僅有 SwiftUI Button action，天然 main thread；precondition 是
    /// 未來如果被誤用於 background thread 時的防線，Debug/Release 都檢查。
    ///
    /// 寫檔策略見 `persistFontSize(_:)`。
    static func setFontSize(_ value: CGFloat) {
        dispatchPrecondition(condition: .onQueue(.main))

        let clamped = clampFontSize(value)
        // clamp 後與當前相同 → no-op：避免白寫檔、空廣播、observer 白跑一輪
        guard clamped != fontSize else {
            debugLog("font_size_noop", ["requested": value, "current": fontSize])
            return
        }

        fontSize = clamped

        persistFontSize(clamped)

        NotificationCenter.default.post(name: .atelioFontSizeChanged, object: nil)

        debugLog("font_size_changed", [
            "value": clamped,
            "requested": value
        ])
    }

    /// 重設字體大小到預設值
    static func resetFontSize() {
        setFontSize(fontSizeDefault)
    }

    /// 將 font_size 合併寫回 config.json（保留其他欄位）
    ///
    /// 安全寫回策略：
    /// - 檔案不存在 → 建立 minimal JSON（含 font_size）
    /// - 檔案存在且 parse 成功 → 合併 font_size、保留其他欄位
    /// - 檔案存在但 parse 失敗 → **不覆寫原檔**，只 log；避免吃掉使用者的 additional_ai_clis
    ///   等現有設定。使用者需手動修好 config.json 格式，下次 set 才會生效。
    private static func persistFontSize(_ value: CGFloat) {
        let path = configPath
        let fm = FileManager.default

        // 確保目錄存在（極罕見情況：~/.atelio 被刪）
        try? fm.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = [:]
        let fileExists = fm.fileExists(atPath: path.path)

        if fileExists {
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                // 既有檔案無法 parse：拒絕覆寫，避免吃掉其他欄位
                debugLog("config_font_write_skipped_parse_fail", [
                    "path": path.path,
                    "reason": "既有 config.json 不是有效 JSON object，為避免覆寫使用者設定，本次不寫檔"
                ])
                return
            }
            json = dict
        }

        json["font_size"] = Double(value)

        // 寫回（pretty printed，穩定 key 排序）
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: options) {
            do {
                try newData.write(to: path, options: [.atomic])
                debugLog("config_font_write_ok", [
                    "path": path.path,
                    "size": newData.count,
                    "merged_existing": fileExists
                ])
            } catch {
                debugLog("config_font_write_fail", [
                    "path": path.path,
                    "error": error.localizedDescription
                ])
            }
        } else {
            debugLog("config_font_serialize_fail", [:])
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// 字體大小變更廣播：所有 TerminalSession 監聽並套用
    static let atelioFontSizeChanged = Notification.Name("AtelioFontSizeChanged")
}
