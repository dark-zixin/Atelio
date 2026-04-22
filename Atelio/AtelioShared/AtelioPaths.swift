import Foundation

/// Atelio 使用者目錄 `~/.atelio/` 下所有檔案路徑的統一管理。
///
/// 設計目的：
/// - 消除散落在各處的 `homeDirectoryForCurrentUser.appendingPathComponent(".atelio")`
/// - Bootstrap 單一入口 `ensureRoot()`，App 啟動最早期呼叫一次
/// - App target 與 CLI target 共用同一份路徑定義
///
/// 非目標：
/// - 不管各檔案的內容語意（config.json 的欄位由 `AtelioConfig` 負責，
///   notify.sh 的內容由 hook 安裝邏輯負責）
public enum AtelioPaths {

    /// 使用者資料根目錄：`~/.atelio/`
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atelio")
    }

    /// 設定檔：`~/.atelio/config.json`
    public static var configPath: URL {
        root.appendingPathComponent("config.json")
    }

    /// Debug log：`~/.atelio/debug.log`
    public static var debugLogPath: URL {
        root.appendingPathComponent("debug.log")
    }

    /// Hook log：`~/.atelio/hook.log`
    public static var hookLogPath: URL {
        root.appendingPathComponent("hook.log")
    }

    /// Hook 通知腳本：`~/.atelio/notify.sh`（內容由未來 hook 自動安裝功能寫入）
    public static var notifyScriptPath: URL {
        root.appendingPathComponent("notify.sh")
    }

    /// IPC Unix domain socket：`~/.atelio/atelio.sock`
    ///
    /// 以 `String` 回傳，供 `sockaddr_un.sun_path` 直接使用 `utf8CString`，
    /// 省掉 `.path` 轉換。
    public static var socketPath: String {
        root.appendingPathComponent("atelio.sock").path
    }

    /// 確保 `~/.atelio/` 存在。App 啟動最早期呼叫一次即可。
    ///
    /// 設計為 idempotent：目錄已存在時不做任何事、也不視為錯誤。
    /// 失敗時 log 並回傳 false，呼叫端可選擇是否繼續。大多數情況下建議
    /// 忽略回傳值——後續任何寫入若真的失敗會各自有錯誤訊息，fail-open
    /// 比 fatal 更符合現況（log 寫不出來只是丟觀測能力，不影響核心功能）。
    @discardableResult
    public static func ensureRoot() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            NSLog("[AtelioPaths] ensureRoot 失敗: %@ path=%@",
                  error.localizedDescription, root.path)
            return false
        }
    }
}
