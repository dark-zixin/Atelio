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
/// 快取與過期：以 shell 設定檔（`.zshrc` / `.zprofile` / `.zshenv` / `.zlogin`、以及
/// `ZDOTDIR` 下對應檔）的 mtime 為簽章，任一變動即失效；另設 TTL 兜底，涵蓋未列入監看的
/// 來源（如 `/etc/paths*`）。命中快取時呼叫端零成本；簽章變動但已有舊值時採
/// stale-while-revalidate（先回舊值、背景更新），避免阻塞建立 worker 的 main thread。
///
/// 限制：以 zsh / bash 的 `-lic` 撈取；若使用者 login shell 為 fish 等語法不同者會撈取
/// 失敗並 fallback 回 App process PATH。
enum AtelioShellEnv {

    // MARK: - 參數

    /// 單次撈取的逾時上限（秒）：涵蓋「讀輸出」與「子程序退出」兩段。
    private static let fetchTimeout: TimeInterval = 5
    /// 快取存活上限（秒）：兜底未列入 mtime 監看的 PATH 來源（如 /etc/paths*）。
    private static let cacheTTL: TimeInterval = 600
    /// 撈取失敗後的 backoff（秒）：期間不重撈，先回舊值，避免壞 / 慢的 rc 反覆拖累。
    private static let failureBackoff: TimeInterval = 30
    /// 輸出邊界標記：把 `$PATH` 夾在兩個 marker 之間印出，只解析中間內容，
    /// 杜絕 interactive shell 的 banner / 警告 / ANSI escape 混入 PATH。
    private static let pathMarker = "__ATELIO_PATH_BOUNDARY__"

    // MARK: - 狀態

    private struct Cache {
        let path: String
        let signature: [String: TimeInterval]
        let fetchedAt: Date
    }

    private static let lock = NSLock()
    private static var cache: Cache?
    /// 是否已有背景撈取進行中（合併重複請求，避免並發重撈）。
    private static var isFetching = false
    /// 最近一次撈取失敗時間，用於 backoff。
    private static var lastFailureAt: Date?

    // MARK: - 對外

    /// 背景預撈，warm-up 快取。在 App 啟動 bootstrap 時呼叫，讓使用者開第一個 worker
    /// 時命中快取、不必同步撈取。
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = resolvedPath()
        }
    }

    /// 解析後的完整 PATH。
    /// - 命中有效快取（簽章一致且未過 TTL）：立即回，亞毫秒、不阻塞。
    /// - 簽章變動 / TTL 到，但有舊快取：回舊值並背景更新（stale-while-revalidate），
    ///   不阻塞呼叫端（建立 worker 多在 main thread）。
    /// - 撈取失敗 backoff 期間：回舊值，不重撈。
    /// - 冷啟動（無任何快取）：同步撈一次（受 fetchTimeout 上界）；prewarm 通常已避免此路徑。
    /// 撈取最終失敗且無舊值時回 nil，由呼叫端 fallback 回 App process PATH。
    static func resolvedPath() -> String? {
        lock.lock()
        let signature = currentSignature()
        if let cache, cache.signature == signature,
           Date().timeIntervalSince(cache.fetchedAt) < cacheTTL {
            lock.unlock()
            return cache.path
        }
        let stale = cache?.path
        let inBackoff = lastFailureAt.map { Date().timeIntervalSince($0) < failureBackoff } ?? false
        lock.unlock()

        // backoff 期間不重撈，先用舊值（避免壞 / 慢 rc 反覆卡）
        if inBackoff {
            return stale
        }

        // 有舊快取：立即回舊值，背景更新，不阻塞呼叫端
        if let stale {
            startBackgroundFetch(signature: signature)
            return stale
        }

        // 冷啟動：無舊值可回，只能同步撈一次（有界）
        return performFetch(signature: signature)
    }

    // MARK: - 撈取協調

    /// 啟動一次背景撈取（已有撈取進行中則略過，合併重複請求）。
    private static func startBackgroundFetch(signature: [String: TimeInterval]) {
        lock.lock()
        if isFetching {
            lock.unlock()
            return
        }
        isFetching = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            _ = performFetch(signature: signature)
            lock.lock()
            isFetching = false
            lock.unlock()
        }
    }

    /// 撈取並更新快取。實際 I/O（`fetchLoginPath`）在鎖外進行，鎖只保護狀態更新，
    /// 避免所有呼叫端（含 main thread）串在同一把鎖上等 I/O。
    @discardableResult
    private static func performFetch(signature: [String: TimeInterval]) -> String? {
        let fetched = fetchLoginPath()
        lock.lock()
        if let fetched {
            cache = Cache(path: fetched, signature: signature, fetchedAt: Date())
            lastFailureAt = nil
        } else {
            lastFailureAt = Date()
        }
        let result = fetched ?? cache?.path
        lock.unlock()
        return result
    }

    /// 跑 `login + interactive` shell 撈 `$PATH`。stderr / stdin 皆導向 null。
    /// 逾時、非零退出或解析失敗皆回 nil。
    private static func fetchLoginPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath())
        // -l login（讀 .zprofile）、-i interactive（讀 .zshrc，使用者 PATH 多設在此）、-c。
        // 用 marker 夾住 $PATH，避免 shell 啟動時印到 stdout 的雜訊混入。
        process.arguments = ["-lic", "printf '%s%s%s' '\(pathMarker)' \"$PATH\" '\(pathMarker)'"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // terminationHandler 必須在 run() 前設，否則 process 提早退出時不會觸發。
        let exitDone = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitDone.signal() }

        do {
            try process.run()
        } catch {
            AtelioConfig.debugLog("shellenv_fetch_failed", ["error": error.localizedDescription])
            return nil
        }

        // 背景讀輸出；主流程以單一 deadline 同時等「讀完成」與「process 退出」。
        // 只等其一不夠：若 shell 關掉 stdout 卻不退出，讀會 EOF 完成、但 process 不退，
        // 單純 waitUntilExit() 會無限阻塞，故兩者都要納入同一個 deadline。
        let readDone = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global().async {
            output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        let deadline = DispatchTime.now() + fetchTimeout
        let readOK = readDone.wait(timeout: deadline) == .success
        let exitOK = exitDone.wait(timeout: deadline) == .success
        guard readOK, exitOK else {
            terminateAndReap(process, readPipe: outputPipe, exitDone: exitDone)
            AtelioConfig.debugLog("shellenv_fetch_timeout", [:])
            return nil
        }

        guard process.terminationStatus == 0,
              let path = parseMarkedPath(output) else {
            AtelioConfig.debugLog("shellenv_fetch_empty", ["status": Int(process.terminationStatus)])
            return nil
        }

        let cleaned = dedupePath(path)
        AtelioConfig.debugLog("shellenv_resolved", ["path": cleaned])
        return cleaned
    }

    /// 逾時清理：SIGTERM → 短 grace → SIGKILL → reap，最後關閉讀端喚醒背景 reader，
    /// 避免殘留 zombie 子程序或永久阻塞的讀取 thread。
    private static func terminateAndReap(_ process: Process,
                                         readPipe: Pipe,
                                         exitDone: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
            if exitDone.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitDone.wait(timeout: .now() + 1)
            }
        }
        // 關讀端：若背景 reader 仍卡在 readDataToEndOfFile（極端情況：孤兒子程序持有寫端），
        // 關閉可使其解除阻塞結束，避免 thread 洩漏。
        try? readPipe.fileHandleForReading.close()
    }

    // MARK: - 解析與工具

    /// 取出兩個 marker 之間的 PATH。marker 之外的 shell 啟動雜訊一律排除。
    private static func parseMarkedPath(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8),
              let start = raw.range(of: pathMarker),
              let end = raw.range(of: pathMarker, range: start.upperBound..<raw.endIndex) else {
            return nil
        }
        let path = String(raw[start.upperBound..<end.lowerBound])
        guard path.contains("/"), !path.contains("\n") else { return nil }
        return path
    }

    /// 帳號的 login shell：以 `getpwuid` 為準（最權威），取不到再退回 `SHELL` env，
    /// 最後固定 `/bin/zsh`（worker 本就以 zsh 啟動）。
    private static func loginShellPath() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty {
                return path
            }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// 受監看的 shell 設定檔：任一 mtime 變動即視為快取失效。
    /// 涵蓋家目錄的 zsh rc 與（若有設定）`ZDOTDIR` 下對應檔；系統層 `/etc/paths*` 等
    /// 不逐一監看，改由 TTL 兜底（極少變動）。
    private static var watchedFiles: [URL] {
        let names = [".zshrc", ".zprofile", ".zshenv", ".zlogin"]
        var urls = names.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }
        if let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"], !zdotdir.isEmpty {
            let base = URL(fileURLWithPath: zdotdir)
            urls += names.map { base.appendingPathComponent($0) }
        }
        return urls
    }

    /// 目前各監看檔的 mtime 簽章（檔案不存在則該項缺席，故新增 / 刪除 rc 檔也會改變簽章）。
    private static func currentSignature() -> [String: TimeInterval] {
        var signature: [String: TimeInterval] = [:]
        for url in watchedFiles {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            signature[url.path] = modified.timeIntervalSince1970
        }
        return signature
    }

    /// 去重並移除空 segment。
    /// - 去重：login + interactive 常各 prepend 一輪造成重複目錄，去掉重複（保留首次出現順序）。
    /// - 移除空 segment：PATH 中的空 segment 等同 current working directory，是公認的安全
    ///   反模式（會在 cwd 執行同名程式）；worker 不依賴 cwd-in-PATH，移除反而更安全。
    ///   此為刻意設計，非遺漏。
    private static func dedupePath(_ path: String) -> String {
        var seen = Set<String>()
        let segments = path.split(separator: ":").map(String.init).filter { segment in
            guard !segment.isEmpty else { return false }
            return seen.insert(segment).inserted
        }
        return segments.joined(separator: ":")
    }
}
