import Foundation

/// 解析使用者 login shell 的完整 PATH，供 worker PTY 注入使用。
///
/// 問題背景：GUI app 從 Dock / Launchpad / Spotlight 啟動時，繼承的是 launchd 的殘缺
/// PATH（`/usr/bin:/bin:/usr/sbin:/sbin`），而 worker 用 `zsh -c` 啟動又是 non-login
/// non-interactive、不讀 `~/.zshrc`，於是 codex / claude / gemini 等裝在 homebrew /
/// nvm / `~/.local/bin` 的 AI CLI 全部「command not found」。開發階段從 Xcode / 終端
/// 啟動時 PATH 是完整的，看似沒事；一旦正式版從 Dock 啟動就 100% 觸發。
///
/// 解法（同 iTerm2 開完整 shell、VS Code 的 shell-env 思路）：跑一次 `login + interactive`
/// shell 把使用者 `~/.zshrc` 補好的完整 PATH 撈回來，快取後注入 worker 環境。worker 本身
/// 仍用輕量的 `zsh -c`，不必每次扛整套互動 shell（prompt / 補全 / 外掛）的啟動成本。
///
/// 過期策略：以 `~/.zshrc` / `~/.zprofile` / `~/.zshenv` 的 mtime 為快取簽章。使用者
/// 安裝新 CLI 而需要新增 PATH 目錄時，通常會改這些檔案，mtime 一變即重撈，避免「裝了
/// 新工具卻讀不到」。往「已在 PATH 的目錄」加檔案（如 `brew install`）不影響、不需重撈。
enum AtelioShellEnv {

    /// 快取：撈到的 PATH + 撈取當下各 rc 檔的 mtime 簽章。
    private struct Cache {
        let path: String
        let signature: [String: TimeInterval]
    }

    private static var cache: Cache?
    private static let lock = NSLock()

    /// 撈取 login shell 的逾時上限（秒）。避免某些 zshrc 卡住（例如等網路）拖垮開 worker。
    private static let fetchTimeout: TimeInterval = 5

    /// 受監看的 shell 設定檔。任一 mtime 變動即視為快取失效。
    private static var watchedFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zprofile", ".zshenv"].map {
            home.appendingPathComponent($0)
        }
    }

    /// 目前各監看檔的 mtime 簽章（檔案不存在則該項缺席，故新增 / 刪除 rc 檔也會改變簽章）。
    private static func currentSignature() -> [String: TimeInterval] {
        var signature: [String: TimeInterval] = [:]
        for url in watchedFiles {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            signature[url.lastPathComponent] = modified.timeIntervalSince1970
        }
        return signature
    }

    /// 背景預撈，warm-up 快取。在 App 啟動 bootstrap 時呼叫，讓使用者開第一個 worker
    /// 時快取多半已就緒，不必同步阻塞 main thread。
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = resolvedPath()
        }
    }

    /// 解析後的完整 PATH。快取簽章未變則直接回；否則撈一次 login shell PATH。
    /// 撈取失敗時回上一份快取（若有），再無則回 nil，由呼叫端自行 fallback。
    ///
    /// 註：撈取（約 1 秒）目前在持鎖期間進行，以避免 warm-up 與開 worker 同時重複撈取。
    /// 因撈取頻率極低（僅冷啟動或 rc 檔變動時），且 warm-up 設計上會先完成，故換取實作簡單。
    static func resolvedPath() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let signature = currentSignature()
        if let cache, cache.signature == signature {
            return cache.path
        }

        guard let path = fetchLoginPath() else {
            return cache?.path
        }
        cache = Cache(path: path, signature: signature)
        return path
    }

    /// 跑 `login + interactive` shell 撈 `$PATH`。stderr 全丟（過濾 prompt / 外掛雜訊），
    /// 逾時、非零退出或空輸出皆回 nil。
    ///
    /// 限制：以 `-lic` + `printf %s "$PATH"` 撈取，適用 zsh / bash；若使用者預設 shell 為
    /// fish 等語法不同者會失敗並回 nil，由呼叫端 fallback 回 App process PATH。
    private static func fetchLoginPath() -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // -l login（讀 .zprofile）、-i interactive（讀 .zshrc，使用者 PATH 多設在此）、
        // -c 執行單一命令。printf 不帶換行，輸出純 PATH 字串。
        process.arguments = ["-lic", "printf %s \"$PATH\""]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            AtelioConfig.debugLog("shellenv_fetch_failed", ["error": error.localizedDescription])
            return nil
        }

        // 背景讀取輸出，主執行緒以 semaphore 做逾時控制。
        let semaphore = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global().async {
            output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + fetchTimeout) == .timedOut {
            process.terminate()
            AtelioConfig.debugLog("shellenv_fetch_timeout", [:])
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let raw = String(data: output, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.contains("/") else {
            AtelioConfig.debugLog("shellenv_fetch_empty",
                                  ["status": Int(process.terminationStatus)])
            return nil
        }

        let cleaned = dedupePath(raw)
        AtelioConfig.debugLog("shellenv_resolved", ["path": cleaned])
        return cleaned
    }

    /// 去重：login + interactive 常各 prepend 一輪，造成重複目錄。去掉重複（保留首次
    /// 出現順序），結果較乾淨、查找也略快。
    private static func dedupePath(_ path: String) -> String {
        var seen = Set<String>()
        let segments = path.split(separator: ":").map(String.init).filter { segment in
            guard !segment.isEmpty else { return false }
            return seen.insert(segment).inserted
        }
        return segments.joined(separator: ":")
    }
}
