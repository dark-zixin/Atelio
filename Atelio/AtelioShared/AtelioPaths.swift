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

    /// Hook 通知腳本：`~/.atelio/notify.sh`（App bootstrap 時根據 marker 比對寫入）
    public static var notifyScriptPath: URL {
        root.appendingPathComponent("notify.sh")
    }

    /// CLI binary 目錄：`~/.atelio/bin/`（symlink 指向 App bundle 內的 AtelioCLI）
    public static var binPath: URL {
        root.appendingPathComponent("bin")
    }

    /// AtelioCLI symlink：`~/.atelio/bin/atelio`
    ///
    /// notify.sh 內 CLI_PATH 永遠指向這個固定路徑，App 啟動時 bootstrap 把
    /// 它指向當下 bundle 內的真實 binary。debug / release / 移動 App 都靠
    /// symlink 收斂，notify.sh 不需要動。
    public static var atelioCLISymlinkPath: URL {
        binPath.appendingPathComponent("atelio")
    }

    /// notify.sh 第二行的 marker（hashbang 後固定位置）。
    ///
    /// 比對採 strict 整行 strcmp：使用者刪掉或改任一字元就視為「我接管了
    /// notify.sh」，App 不再覆寫。意外改了內容但 marker 還在的 case 仍會
    /// 被覆寫，trade-off 是「90% 使用者沒理由動 notify.sh」 + 「opt-out
    /// 行為直觀（刪整行）」。
    public static let notifyScriptMarker = "# This file is managed by Atelio. Remove this line to take over."

    /// notify.sh 的標準模板。
    ///
    /// 設計：
    /// - 第 1 行 hashbang
    /// - 第 2 行 marker（與 `notifyScriptMarker` 字字相符）
    /// - 第 3 行起為 hook forwarding 邏輯
    ///
    /// 用 Swift const 而非 bundle resource：避開 PBXFileSystemSynchronizedRootGroup
    /// 對未知副檔名的 exception 配置複雜性。內容極短且穩定，inline 反而更可靠。
    /// 修改後重 build App、重啟即可由 ensureNotifyScript 自動更新使用者檔案。
    public static let notifyScriptTemplate = """
        #!/bin/bash
        \(notifyScriptMarker)
        [ -z "$ATELIO_SESSION" ] && exit 0

        event="${1:-unknown}"
        case "$event" in
          turn_start|turn_end) ;;
          *) exit 0 ;;
        esac

        CLI_PATH="${ATELIO_CLI_PATH:-$HOME/.atelio/bin/atelio}"
        [ -x "$CLI_PATH" ] || exit 0

        "$CLI_PATH" notify "$event" >/dev/null 2>&1 || exit 0

        """

    /// Skill 根目錄：`~/.atelio/skills/`
    public static var skillsPath: URL {
        root.appendingPathComponent("skills")
    }

    /// Atelio skill 目錄：`~/.atelio/skills/atelio/`
    ///
    /// 使用者的主 AI（CC / Codex / Gemini 等）可 symlink 或 copy 此目錄到各自的
    /// skill 搜尋路徑，取得最新版說明書。由 `ensureSkill(from:)` 在 App 啟動時
    /// 從 bundle 更新至此目錄。
    public static var skillPath: URL {
        skillsPath.appendingPathComponent("atelio")
    }

    /// 從 App bundle 安裝（或更新）skill 到 `~/.atelio/skills/atelio/`。
    ///
    /// `sourceDirURL` 為 bundle 內的 skill 目錄，例如
    /// `Bundle.main.bundleURL/Contents/Resources/skills/atelio`。
    /// 若 source 不存在（CLI 環境、測試環境）則靜默跳過，回傳 true。
    /// 若目的地已存在則先移除再複製，確保每次 App 啟動都能更新至 bundle 版本。
    @discardableResult
    public static func ensureSkill(from sourceDirURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceDirURL.path) else { return true }

        do {
            try fm.createDirectory(at: skillsPath, withIntermediateDirectories: true)
            if fm.fileExists(atPath: skillPath.path) {
                try fm.removeItem(at: skillPath)
            }
            try fm.copyItem(at: sourceDirURL, to: skillPath)
            NSLog("[AtelioPaths] ensureSkill: 安裝至 %@", skillPath.path)
            return true
        } catch {
            NSLog("[AtelioPaths] ensureSkill: 安裝失敗: %@ source=%@",
                  error.localizedDescription, sourceDirURL.path)
            return false
        }
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

    /// 確保 `~/.atelio/bin/` 存在。idempotent。
    @discardableResult
    public static func ensureBin() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: binPath,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            NSLog("[AtelioPaths] ensureBin 失敗: %@ path=%@",
                  error.localizedDescription, binPath.path)
            return false
        }
    }

    /// 把 `~/.atelio/bin/atelio` 指向給定的 target binary。
    ///
    /// 行為：
    /// - 路徑不存在 → 建 symlink
    /// - 路徑存在且是 symlink → 不論 target 一致與否都 unlink + 重建
    ///   （成本極低，省掉 readlink 比對）
    /// - 路徑存在但**不是 symlink**（regular file / dir）→ 不動 + log warning
    ///   （保護使用者意外放在這位置的東西）
    @discardableResult
    public static func updateCLISymlink(target: URL) -> Bool {
        let symlinkURL = atelioCLISymlinkPath
        let fm = FileManager.default

        // 用 lstat 判斷是否為 symlink（resolveSymlinksInPath 會被自動跟隨）
        var statBuf = stat()
        let lstatResult = lstat(symlinkURL.path, &statBuf)

        if lstatResult == 0 {
            let isSymlink = (statBuf.st_mode & S_IFMT) == S_IFLNK
            if !isSymlink {
                NSLog("[AtelioPaths] updateCLISymlink: 路徑已存在且非 symlink，不動 path=%@",
                      symlinkURL.path)
                return false
            }
            // 是 symlink → unlink 重建
            do {
                try fm.removeItem(at: symlinkURL)
            } catch {
                NSLog("[AtelioPaths] updateCLISymlink: 移除舊 symlink 失敗: %@ path=%@",
                      error.localizedDescription, symlinkURL.path)
                return false
            }
        }

        do {
            try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: target)
            return true
        } catch {
            NSLog("[AtelioPaths] updateCLISymlink: 建立 symlink 失敗: %@ symlink=%@ target=%@",
                  error.localizedDescription, symlinkURL.path, target.path)
            return false
        }
    }

    /// 根據 marker 比對結果寫入 `~/.atelio/notify.sh`。
    ///
    /// 行為：
    /// - 不存在 → 寫入 template
    /// - 存在，hashbang 後第二行 == `notifyScriptMarker` → 視為 Atelio 自管，覆寫成 template
    /// - 存在，第二行 != marker → 視為使用者接管，不動 + log warning
    /// - 存在但無法讀取 → 不動 + log warning（避免覆寫不確定狀態）
    ///
    /// `template` 預期已含 marker 行於第 2 行（由 caller 提供，目前由
    /// `notifyScriptTemplate` const 供應）。比對時容忍 trailing CR
    /// （cross-platform 工具寫出的 \r\n 行尾不會被誤判為使用者接管）。
    @discardableResult
    public static func ensureNotifyScript(template: String) -> Bool {
        let path = notifyScriptPath
        let fm = FileManager.default

        if !fm.fileExists(atPath: path.path) {
            return writeNotifyScript(template: template, reason: "首次建立")
        }

        let existing: String
        do {
            existing = try String(contentsOf: path, encoding: .utf8)
        } catch {
            NSLog("[AtelioPaths] ensureNotifyScript: 讀取既有檔案失敗，不動: %@ path=%@",
                  error.localizedDescription, path.path)
            return false
        }

        let lines = existing.components(separatedBy: "\n")
        // 容忍 CRLF：cross-platform 工具（VSCode autocrlf 等）寫出 \r\n 行尾
        // 在 split by "\n" 後第二行尾部會留一個 \r，不該被誤判為使用者接管。
        let secondLine = (lines.count >= 2 ? lines[1] : "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))

        if secondLine == notifyScriptMarker {
            return writeNotifyScript(template: template, reason: "marker 命中，更新為當前模板")
        }

        NSLog("[AtelioPaths] ensureNotifyScript: 既有檔案無 marker（使用者已接管），不覆寫 path=%@",
              path.path)
        return false
    }

    private static func writeNotifyScript(template: String, reason: String) -> Bool {
        let path = notifyScriptPath
        do {
            try template.write(to: path, atomically: true, encoding: .utf8)
            // 設定執行權限 0755
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: path.path
            )
            NSLog("[AtelioPaths] ensureNotifyScript: %@ path=%@", reason, path.path)
            return true
        } catch {
            NSLog("[AtelioPaths] ensureNotifyScript: 寫入失敗: %@ path=%@",
                  error.localizedDescription, path.path)
            return false
        }
    }
}
