import Foundation
import AtelioShared

/// 分層 log：運作診斷層（ops）與開發追蹤層（trace）。
///
/// 設計（詳見 doc/0612_log-tiering-design.md）：
/// - `ops`：永遠記錄。異常、降級、罕見且高診斷價值的事件——正式環境出問題時的現場證據
/// - `trace`：gate 開啟時才記錄。全路徑追蹤，開發期重現問題用
/// - gate 預設值跟 build configuration（Debug 開 / Release 關），
///   config.json 的 `trace_log` 欄位可覆寫（Release 現場診斷的逃生門）
/// - 單一檔案 `~/.atelio/atelio.log`，超過 2MB 輪替成 `atelio.log.old`（最壞佔用 4MB）
/// - 所有寫入經 serial queue 串行化，避免多執行緒互踩壞行
enum AtelioLog {

    // MARK: - Trace gate

    /// trace 層是否啟用。不加鎖：變更只在 App 啟動早期的 config 載入發生一次
    /// （早於 IPC server 啟動，無並行寫入），之後純讀取。
    private(set) static var traceEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// 覆寫 trace gate（config.json `trace_log` 欄位載入時呼叫）。
    static func setTraceEnabled(_ on: Bool) {
        traceEnabled = on
    }

    // MARK: - 公開 API

    /// 運作診斷層：永遠記錄 + NSLog（檔案寫不出來時 Console.app 仍有備份）。
    static func ops(_ event: String, _ data: [String: Any] = [:]) {
        NSLog("[Atelio] %@ %@", event, data.description)
        write(event: event, data: data)
    }

    /// 開發追蹤層：gate 開啟時記錄。NSLog 只在 Debug build 發
    /// （Xcode console 即時看；Release 開 trace_log 時只進檔案，不灌爆 unified log）。
    static func trace(_ event: String, _ data: [String: Any] = [:]) {
        guard traceEnabled else { return }
        #if DEBUG
        NSLog("[Atelio] %@ %@", event, data.description)
        #endif
        write(event: event, data: data)
    }

    // MARK: - 寫入器

    /// 輪替門檻：寫入後檔案超過此大小 → rename 成 .old（覆蓋舊的）→ 立即開新檔。
    /// ops 事件一行 < 200 bytes，2MB ≈ 上萬筆異常；最壞佔用 = 2 檔 ×（2MB + 單行上限）。
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    /// 單行上限：超過即截斷。讓「最壞佔用」成為 writer 自身的不變量，
    /// 不依賴呼叫點自律（trace 的 dispatch_payload 可能夾帶整包 payload，
    /// IPC frame 上限 10MB 遠大於輪替門檻）。
    private static let maxLineBytes = 64 * 1024

    /// 所有檔案操作（開檔、寫入、輪替）都在這條 serial queue 上，
    /// 取代舊 debugLog 的 FileHandle seek+write 非原子寫法。
    private static let queue = DispatchQueue(label: "atelio.log.writer")

    /// 常駐 FileHandle 與已寫大小追蹤（只在 queue 上存取）。
    private static var handle: FileHandle?
    private static var currentSize: UInt64 = 0

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func write(event: String, data: [String: Any]) {
        // 時間戳在呼叫端執行緒取（進 queue 後才取會因排隊延遲失真）
        let timestamp = timestampFormatter.string(from: Date())
        var parts = [timestamp, "event=\(event)"]
        for (key, value) in data.sorted(by: { $0.key < $1.key }) {
            let str = "\(value)".replacingOccurrences(of: "\n", with: "\\n")
            parts.append("\(key)=\(str)")
        }
        var line = parts.joined(separator: " ")
        if line.utf8.count > maxLineBytes {
            // 預扣 suffix 與換行；邊界判斷與 UTF-8 替換字元收尾可有數 bytes 誤差，
            // 對 2MB 輪替的空間保證無實質影響
            let suffix = " …[line_truncated]"
            let prefixBytes = maxLineBytes - suffix.utf8.count - 1
            line = String(decoding: Array(line.utf8.prefix(prefixBytes)), as: UTF8.self) + suffix
        }
        let data = Data((line + "\n").utf8)

        queue.async {
            appendOnQueue(data)
        }
    }

    /// 只能在 `queue` 上呼叫。
    private static func appendOnQueue(_ line: Data) {
        // Unix 對已刪除檔案的 fd 寫入不會報錯（寫進孤兒 inode），
        // 必須主動比對 inode 偵測「檔案被外部刪除 / 改名」後重開
        if handleIsStale() {
            try? handle?.close()
            handle = nil
        }
        if handle == nil {
            openOnQueue()
        }
        guard let h = handle else { return }

        do {
            try h.write(contentsOf: line)
        } catch {
            // 寫入失敗（磁碟滿等）：丟棄 handle，下次寫入重開重試
            handle = nil
            return
        }
        // 取 fstat 真實大小而非自行累計：涵蓋外部 append 等自己看不到的增長
        currentSize = fileSizeOnQueue()

        if currentSize > maxLogBytes {
            rotateOnQueue()
        }
    }

    /// 只能在 `queue` 上呼叫。目前 handle 指向檔案的真實大小。
    private static func fileSizeOnQueue() -> UInt64 {
        guard let h = handle else { return 0 }
        var st = stat()
        guard fstat(h.fileDescriptor, &st) == 0 else { return 0 }
        return UInt64(st.st_size)
    }

    /// 只能在 `queue` 上呼叫。常駐 handle 指向的 inode 與路徑現況不符
    /// （被刪、被改名、被替換）即視為 stale。
    private static func handleIsStale() -> Bool {
        guard let h = handle else { return false }
        var fdStat = stat()
        guard fstat(h.fileDescriptor, &fdStat) == 0 else { return true }
        var pathStat = stat()
        guard AtelioPaths.logPath.path.withCString({ stat($0, &pathStat) }) == 0 else {
            return true
        }
        return fdStat.st_dev != pathStat.st_dev || fdStat.st_ino != pathStat.st_ino
    }

    /// 只能在 `queue` 上呼叫。以 O_APPEND 開（或建）log 檔。
    ///
    /// O_APPEND 讓每筆 write 原子落在當下 EOF——一次性 seekToEnd 不夠：
    /// fd 的寫入位置停在自己上次寫的地方，檔案被外部 append 後會覆寫中段。
    ///
    /// 保留 defensive mkdir：logger 可能在 `AtelioPaths.ensureRoot()` 之前
    /// 或失敗的情境下被呼叫（例如記錄 bootstrap 本身的失敗），
    /// 必須自帶目錄建立才能保證合約。
    private static func openOnQueue() {
        try? FileManager.default.createDirectory(
            at: AtelioPaths.root, withIntermediateDirectories: true)

        // O_CLOEXEC：避免 log fd 被 worker 子程序（forkpty/exec）繼承——
        // 子程序持有已被輪替 unlink 的舊 inode 會造成不可見的磁碟佔用
        let fd = AtelioPaths.logPath.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { return }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        currentSize = fileSizeOnQueue()
    }

    /// 只能在 `queue` 上呼叫。關檔 → rename 成 .old（覆蓋既有）→ 立即開新檔。
    /// 立即重開讓 `atelio.log` 路徑隨時可讀，不會在輪替後、下筆寫入前撲空。
    private static func rotateOnQueue() {
        try? handle?.close()
        handle = nil
        currentSize = 0

        let fm = FileManager.default
        try? fm.removeItem(at: AtelioPaths.logRotatedPath)
        try? fm.moveItem(at: AtelioPaths.logPath, to: AtelioPaths.logRotatedPath)

        openOnQueue()

        // rename 失敗的 fallback：重開後仍超標代表搬移沒成功，
        // 直接清空現檔保住「不可無限增長」的硬上限（此病態情境下保空間優先於保內容）
        if let h = handle, fileSizeOnQueue() > maxLogBytes {
            ftruncate(h.fileDescriptor, 0)
            currentSize = 0
        }
    }
}
