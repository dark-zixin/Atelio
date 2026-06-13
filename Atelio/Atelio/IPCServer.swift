import Foundation
import AtelioShared
import SwiftTerm

/// Unix domain socket server，接收 CLI 指令並路由到 TerminalManager
class IPCServer {

    static var socketPath: String { AtelioPaths.socketPath }

    /// 回應取樣目錄（去噪等實驗用，預設 nil = 關閉）。
    /// 不屬於 log 體系：需要取樣時暫時改成目標路徑、實驗完改回 nil。
    static var responseLogDir: String? = nil

    private let manager: TerminalManager
    private let dispatchActivity: DispatchActivity
    private var serverFd: Int32 = -1
    private var isRunning = false

    /// reset 穩定閘閾值（秒）：畫面靜止需達此秒數才允許 reset。
    /// 取 5 秒對齊非 hook session 的 quiet window（codex review 建議 5-10 秒區間）。
    private static let resetQuietThreshold: TimeInterval = 5

    init(manager: TerminalManager, dispatchActivity: DispatchActivity) {
        self.manager = manager
        self.dispatchActivity = dispatchActivity
    }

    // MARK: - 啟動與停止

    /// 啟動 IPC server
    func start() throws {
        let path = IPCServer.socketPath

        // sockaddr_un.sun_path 在 macOS 為 104 bytes（含 null）。
        // 目前路徑 ~/.atelio/atelio.sock 在正常使用者名下約 40 字元，遠低於上限；
        // 一次性 precondition 防未來 root 路徑改長或使用者名異常長時靜默 truncate。
        let byteCount = path.utf8CString.count
        precondition(byteCount <= 104,
                     "IPC socket path 超過 sockaddr_un.sun_path 上限: \(byteCount) bytes, path=\(path)")

        // 清除舊的 socket 檔案
        unlink(path)

        // 建立 socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw IPCError.connectionFailed
        }

        // 綁定到路徑
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFd)
            throw IPCError.connectionFailed
        }

        // 開始監聽
        guard listen(serverFd, 5) == 0 else {
            Darwin.close(serverFd)
            throw IPCError.connectionFailed
        }

        isRunning = true

        // 在背景執行緒接受連線
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// 停止 IPC server
    func stop() {
        isRunning = false
        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }
        unlink(IPCServer.socketPath)
    }

    // MARK: - 連線處理

    private func acceptLoop() {
        while isRunning {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else { continue }

            // 每個連線在獨立執行緒處理
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(fd: clientFd)
                Darwin.close(clientFd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        do {
            // 讀取請求
            let requestData = try IPCFraming.readMessage(from: fd)
            let request = try JSONDecoder().decode(IPCRequest.self, from: requestData)

            // 處理請求
            let response = handleRequest(request)

            // 暫時的 logging：記錄有 output 的回應
            Self.logResponse(request: request, response: response)

            // 送出回應
            let responseData = try IPCFraming.encode(response)
            try IPCFraming.writeMessage(responseData, to: fd)
        } catch {
            // 嘗試送出錯誤回應
            let errorResponse = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: error.localizedDescription)
            if let data = try? IPCFraming.encode(errorResponse) {
                try? IPCFraming.writeMessage(data, to: fd)
            }
        }
    }

    // MARK: - 回應 Logging（暫時用於去噪測試）

    /// 記錄有 output 內容的回應到檔案
    private static func logResponse(request: IPCRequest, response: IPCResponse) {
        guard let logDir = responseLogDir,
              let output = response.output, !output.isEmpty else { return }

        let timestamp = {
            let df = DateFormatter()
            df.dateFormat = "HHmmss"
            return df.string(from: Date())
        }()

        let filename = "\(request.name)_\(request.command.rawValue)_\(timestamp).txt"
        let path = (logDir as NSString).appendingPathComponent(filename)

        var content = ""
        content += "session: \(request.name)\n"
        content += "command: \(request.command.rawValue)\n"
        if let text = request.text {
            content += "text: \(text)\n"
        }
        content += "result: \(response.result)\n"
        content += "timestamp: \(Date())\n"
        content += "output_length: \(output.count)\n"
        content += "===== OUTPUT =====\n"
        content += output

        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 請求路由

    private func handleRequest(_ request: IPCRequest) -> IPCResponse {
        switch request.command {
        case .open:
            return handleOpen(request)
        case .dispatch:
            return handleDispatch(request)
        case .status:
            return handleStatus(request)
        case .close:
            return handleClose(request)
        case .screen:
            return handleScreen(request)
        case .wait:
            return handleWait(request)
        case .list:
            return handleList(request)
        case .notify:
            return handleNotify(request)
        case .peek:
            return handlePeek(request)
        case .sendKeys:
            return handleSendKeys(request)
        case .reset:
            return handleReset(request)
        @unknown default:
            // IPCRequest.Command 定義在 AtelioShared module，跨 module 的 enum 被
            // 視為未來可能新增 case；補此分支讓未知指令回報錯誤而非編譯失敗
            // （Swift 6 語言模式下缺這分支會是 error）。
            return IPCResult.response(
                IPCResult.invalidRequest,
                IPCResult.invalidRequestHint,
                message: "未知或不支援的指令"
            )
        }
    }

    /// 讀取 session PTY 的 foreground process group，回傳 basename/path/whitelist 判斷。
    /// 唯讀診斷用，不改任何 session 狀態。
    private func handlePeek(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal(); return
            }
            guard let session = self.manager.sessions[request.name] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint,
                    message: "找不到 session '\(request.name)'")
                semaphore.signal(); return
            }

            let childfd = session.terminalView.process?.childfd ?? -1

            // peek foreground process group
            var fgPgrp: pid_t = -1
            var tcErrno: Int32 = 0
            if childfd >= 0 {
                fgPgrp = tcgetpgrp(childfd)
                if fgPgrp < 0 { tcErrno = errno }
            }

            // proc_name / proc_pidpath（對比用 raw data，不做判斷；pgrp leader pid == pgrp 本身）
            var fgName = ""
            var fgPath = ""
            if fgPgrp > 0 {
                var nameBuf = [CChar](repeating: 0, count: 256)
                let nameLen = proc_name(Int32(fgPgrp), &nameBuf, UInt32(nameBuf.count))
                if nameLen > 0 { fgName = String(cString: nameBuf) }

                var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
                let pathLen = proc_pidpath(Int32(fgPgrp), &pathBuf, UInt32(pathBuf.count))
                if pathLen > 0 { fgPath = String(cString: pathBuf) }
            }

            // argv 掃描（KERN_PROCARGS2）— 權威判斷
            var argv: [String] = []
            if fgPgrp > 0, let fetched = ProcessInspector.argv(for: pid_t(fgPgrp)) {
                argv = fetched
            }
            let argvHit: Any = AtelioConfig.matchAiCli(argv: argv) ?? NSNull()

            // 統合失敗原因為 error 字串（null = 成功）
            let errorValue: Any
            if childfd < 0 {
                errorValue = "no_childfd"
            } else if fgPgrp < 0 {
                errorValue = "tcgetpgrp_fail (errno=\(tcErrno))"
            } else if argv.isEmpty {
                errorValue = "argv_unavailable"
            } else {
                errorValue = NSNull()
            }

            let payload: [String: Any] = [
                "session": request.name,
                "argv": argv,
                "argv_hit": argvHit,
                "fg_name": fgName,
                "fg_path": fgPath,
                "error": errorValue
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "{}"
            response = IPCResult.response(IPCResult.ok, IPCResult.okHint, output: json)
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    /// 驗證 callerPID 是否有權操作 session（dispatch/close/wait 共用）
    private func verifyOwner(session: TerminalSession, callerPID: Int32?, command: String) -> IPCResponse? {
        guard let callerPID = callerPID else { return nil }
        if let owner = session.ownerPID {
            if kill(owner, 0) != 0 {
                return IPCResult.response(IPCResult.ownerMismatch, IPCResult.ownerMismatchHint,
                    message: "此 session 的擁有者已斷開（owner=\(owner)），無法 \(command)")
            } else if owner != callerPID {
                return IPCResult.response(IPCResult.ownerMismatch, IPCResult.ownerMismatchHint,
                    message: "此 session 由其他程序擁有（owner=\(owner)），無權 \(command)")
            }
        }
        return nil
    }

    /// 送 raw keystroke 到 session PTY（不包 bracketed paste、不補 \r、不動 TurnCoordinator）
    /// 用於操作 AI CLI 的 TUI 互動（例如 approval prompt）。
    /// 用 semaphore 同步：在 main queue 查完 session / isRunning / key 翻譯後才 return，
    /// 確保 CLI 收到的 ok 代表「真的 enqueue 到 PTY」。
    private func handleSendKeys(_ request: IPCRequest) -> IPCResponse {
        let key = request.text ?? ""
        let sessionName = request.name

        guard !key.isEmpty else {
            return IPCResult.response(IPCResult.invalidRequest, IPCResult.invalidRequestHint,
                                      message: "send-keys 指令需要 key 參數")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal(); return
            }
            guard let session = self.manager.sessions[sessionName] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint,
                                              message: "找不到 session '\(sessionName)'")
                semaphore.signal(); return
            }
            guard session.isRunning else {
                response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint,
                                              message: "session '\(sessionName)' 的 process 已結束")
                semaphore.signal(); return
            }
            if let err = self.verifyOwner(session: session, callerPID: request.callerPID, command: "send-keys") {
                response = err; semaphore.signal(); return
            }
            // instance translateKey：方向鍵會依 session 當下的 applicationCursor 決定 sequence
            guard let bytes = session.translateKey(key) else {
                response = IPCResult.response(IPCResult.invalidRequest, IPCResult.invalidRequestHint,
                                              message: "不認得的 key: '\(key)'（支援：enter/return/esc/escape/tab/space/bspace/backspace/up/down/left/right/c-<letter>/單字元）")
                semaphore.signal(); return
            }
            session.sendRaw(bytes: bytes, originalKey: key)
            response = IPCResult.response(IPCResult.ok, IPCResult.okHint,
                                          message: "已送 key='\(key)' 到 session '\(sessionName)'")
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return response
    }

    /// 強制結束卡住的 turn，讓 session 回到 idle（逃生門）。
    /// 檢查順序對齊 dispatch/send-keys：sessionNotFound → isRunning → verifyOwner。
    /// 已是 idle 時為 no-op，直接回 ok。
    private func handleReset(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal(); return
            }
            guard let session = self.manager.sessions[request.name] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint,
                                              message: "找不到 session '\(request.name)'")
                semaphore.signal(); return
            }
            guard session.isRunning else {
                response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint,
                                              message: "session '\(request.name)' 的 process 已結束")
                semaphore.signal(); return
            }
            if let err = self.verifyOwner(session: session, callerPID: request.callerPID, command: "reset") {
                response = err; semaphore.signal(); return
            }
            guard session.coordinator.phase != .idle else {
                response = IPCResult.response(IPCResult.ok, IPCResult.okHint,
                                              message: "session '\(request.name)' 已是 idle，無需 reset")
                semaphore.signal(); return
            }
            // 穩定閘：畫面最近仍在變 → worker 可能仍在工作，拒絕 reset。
            // 把 SKILL 的使用規範（畫面停止才能 reset）升級為 server 不變量，
            // 不依賴 caller（AI）自律。閾值 5 秒對齊非 hook quiet window；
            // 合法 reset 場景（ESC 取消後停在 prompt）天然靜止、等待零成本。
            // 不提供 force 跳過：閘會擋的場景（worker 活躍、或掛死但動畫仍跑）
            // 都不是 reset 能救的，繞過只放大誤用面。
            let quietFor = session.coordinator.secondsSinceScreenChange
            if quietFor < Self.resetQuietThreshold {
                response = IPCResult.response(IPCResult.turnInProgress, IPCResult.turnInProgressHint,
                    message: "畫面最近 \(Int(Self.resetQuietThreshold)) 秒內仍在變化，worker 可能仍在工作，已拒絕 reset。"
                        + "若要中止 worker，先用 send-keys（esc 或 c-c）讓畫面停止再 reset；"
                        + "若 worker 已無回應，改用 close 或請使用者在 UI 介入。")
                semaphore.signal(); return
            }
            session.coordinator.abortTurn()
            response = IPCResult.response(IPCResult.ok, IPCResult.okHint,
                                          message: "已強制結束 turn，session '\(request.name)' 回到 idle")
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleNotify(_ request: IPCRequest) -> IPCResponse {
        let event = request.text ?? "unknown"
        let sessionName = request.name

        DispatchQueue.main.async { [weak self] in
            guard let session = self?.manager.sessions[sessionName] else {
                return
            }
            switch event {
            case "turn_start": session.handleTurnStart()
            case "turn_end": session.handleTurnEnd()
            case "approval_needed": session.handleApprovalNeeded()
            default: break
            }
        }

        return IPCResult.response(IPCResult.ok, IPCResult.okHint, message: "已收到 \(event) 通知（session: \(sessionName)）")
    }

    private func handleOpen(_ request: IPCRequest) -> IPCResponse {
        let dir = request.dir ?? "/tmp"
        let cmd = request.cmd ?? "/bin/zsh"
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let purpose = request.purpose ?? ""
                let session = try self.manager.open(name: request.name, purpose: purpose, directory: dir, command: cmd)
                session.ownerPID = request.callerPID
                session.waitForReady(timeout: 5) { [weak self] ready in
                    if ready {
                        response = IPCResult.response(IPCResult.ok, IPCResult.okHint, message: "已開啟 session '\(session.name)'")
                    } else if session.isRunning {
                        response = IPCResult.response(IPCResult.ok, IPCResult.okHint, message: "已開啟 session '\(session.name)'（就緒超時）")
                    } else {
                        self?.manager.sessions.removeValue(forKey: request.name)
                        response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint,
                            message: "session '\(request.name)' 啟動失敗（process 已結束）")
                    }
                    semaphore.signal()
                }
                return
            } catch {
                response = Self.mapManagerError(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleDispatch(_ request: IPCRequest) -> IPCResponse {
        let text = request.text ?? ""
        let timeout = request.timeout ?? 60
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")
        var jobSem: DispatchSemaphore?
        let setupSem = DispatchSemaphore(value: 0)

        // Dispatch 活動計數：進入點 +1，所有離開路徑 -1（用 defer 保證）
        let activity = self.dispatchActivity
        DispatchQueue.main.async { activity.begin() }
        defer { DispatchQueue.main.async { activity.end() } }

        // Step 1: main thread 設定 + 啟動 job
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.manager.sessions[request.name] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint, message: "找不到 session '\(request.name)'")
                setupSem.signal(); return
            }
            guard session.isRunning else {
                response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint, message: "session 已停止")
                setupSem.signal(); return
            }
            if let err = self.verifyOwner(session: session, callerPID: request.callerPID, command: "dispatch") {
                response = err; setupSem.signal(); return
            }
            guard let sem = session.startDispatch(text: text) else {
                response = IPCResult.response(IPCResult.turnInProgress, IPCResult.turnInProgressHint)
                setupSem.signal(); return
            }
            jobSem = sem
            setupSem.signal()
        }

        // Step 2: 等 setup
        setupSem.wait()
        guard let sem = jobSem else { return response }

        // Step 3: 等 job（IPC thread 阻塞）
        let waitResult = sem.wait(timeout: .now() + .seconds(timeout))

        // Step 4: main thread 讀結果
        let resultSem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            guard let session = self?.manager.sessions[request.name] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint)
                resultSem.signal(); return
            }
            if waitResult == .success {
                let output = session.readOutput()
                switch session.coordinator.completionReason {
                case .hookTurnEnded:
                    response = IPCResult.response(IPCResult.hookTurnEnded, IPCResult.hookTurnEndedHint, output: output)
                case .processExited:
                    response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint, output: output)
                case .aborted:
                    response = IPCResult.response(IPCResult.turnAborted, IPCResult.turnAbortedHint, output: output)
                case .approvalNeeded:
                    // worker 跳 approval 選單、turn 未結束：waiter 被即時喚醒，output 帶當前
                    // 畫面（含選單）讓主 AI 直接判斷選項，不必再 screen。處理（send-keys）後重新 wait。
                    response = IPCResult.response(IPCResult.approvalPending, IPCResult.approvalPendingHint, output: output)
                default:
                    response = IPCResult.response(IPCResult.quietWindowMet, IPCResult.quietWindowMetHint, output: output)
                }
            } else {
                if session.coordinator.hookSeen {
                    response = IPCResult.response(IPCResult.turnInProgress, IPCResult.turnInProgressHint)
                } else {
                    let output = session.readOutput()
                    response = IPCResult.response(IPCResult.deadlineReached, IPCResult.deadlineReachedHint, output: output)
                }
            }
            resultSem.signal()
        }
        resultSem.wait()
        return response
    }

    private func handleStatus(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let info = try self.manager.status(name: request.name)
                let json = try JSONEncoder().encode(info)
                let infoStr = String(data: json, encoding: .utf8) ?? "{}"
                response = IPCResult.response(IPCResult.ok, IPCResult.okHint, message: infoStr)
            } catch {
                response = Self.mapManagerError(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleClose(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            // PPID owner 驗證
            if let session = self.manager.sessions[request.name],
               let ownerError = self.verifyOwner(session: session, callerPID: request.callerPID, command: "close") {
                response = ownerError
                semaphore.signal()
                return
            }
            self.manager.close(name: request.name, confirmKey: request.confirmKey) { result in
                response = result
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(10))
        if waitResult == .timedOut {
            response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "close 操作超時")
        }
        return response
    }

    private func handleScreen(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let content = try self.manager.screen(name: request.name)
                response = IPCResult.response(IPCResult.ok, IPCResult.okHint, output: content)
            } catch {
                response = Self.mapManagerError(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleWait(_ request: IPCRequest) -> IPCResponse {
        let timeout = request.timeout ?? 60
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")
        var jobSem: DispatchSemaphore?
        let setupSem = DispatchSemaphore(value: 0)

        // Wait 活動計數：進入點 +1，所有離開路徑 -1（用 defer 保證）
        let activity = self.dispatchActivity
        DispatchQueue.main.async { activity.begin() }
        defer { DispatchQueue.main.async { activity.end() } }

        // Step 1: main thread 設定
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.manager.sessions[request.name] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint, message: "找不到 session '\(request.name)'")
                setupSem.signal(); return
            }
            guard session.isRunning else {
                response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint, message: "session 已停止")
                setupSem.signal(); return
            }
            if let err = self.verifyOwner(session: session, callerPID: request.callerPID, command: "wait") {
                response = err; setupSem.signal(); return
            }
            // phase == .idle → 立刻回畫面
            if session.coordinator.phase == .idle {
                let output = session.readOutput()
                response = IPCResult.response(IPCResult.quietWindowMet, IPCResult.quietWindowMetHint, output: output)
                setupSem.signal(); return
            }
            guard let sem = session.startWait() else {
                let output = session.readOutput()
                response = IPCResult.response(IPCResult.quietWindowMet, IPCResult.quietWindowMetHint, output: output)
                setupSem.signal(); return
            }
            jobSem = sem
            setupSem.signal()
        }

        // Step 2: 等 setup
        setupSem.wait()
        guard let sem = jobSem else { return response }

        // Step 3: 等 job（IPC thread 阻塞）
        let waitResult = sem.wait(timeout: .now() + .seconds(timeout))

        // Step 4: main thread 讀結果
        let resultSem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            guard let session = self?.manager.sessions[request.name] else {
                response = IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint)
                resultSem.signal(); return
            }
            if waitResult == .success {
                let output = session.readOutput()
                switch session.coordinator.completionReason {
                case .hookTurnEnded:
                    response = IPCResult.response(IPCResult.hookTurnEnded, IPCResult.hookTurnEndedHint, output: output)
                case .processExited:
                    response = IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint, output: output)
                case .aborted:
                    response = IPCResult.response(IPCResult.turnAborted, IPCResult.turnAbortedHint, output: output)
                case .approvalNeeded:
                    // worker 跳 approval 選單、turn 未結束：waiter 被即時喚醒，output 帶當前
                    // 畫面（含選單）讓主 AI 直接判斷選項，不必再 screen。處理（send-keys）後重新 wait。
                    response = IPCResult.response(IPCResult.approvalPending, IPCResult.approvalPendingHint, output: output)
                default:
                    response = IPCResult.response(IPCResult.quietWindowMet, IPCResult.quietWindowMetHint, output: output)
                }
            } else {
                if session.coordinator.hookSeen {
                    response = IPCResult.response(IPCResult.turnInProgress, IPCResult.turnInProgressHint)
                } else {
                    let output = session.readOutput()
                    response = IPCResult.response(IPCResult.deadlineReached, IPCResult.deadlineReachedHint, output: output)
                }
            }
            resultSem.signal()
        }
        resultSem.wait()
        return response
    }

    private func handleList(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let infos = self.manager.list()
                let json = try JSONEncoder().encode(infos)
                let jsonStr = String(data: json, encoding: .utf8) ?? "[]"
                response = IPCResult.response(IPCResult.ok, IPCResult.okHint, output: jsonStr)
            } catch {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: error.localizedDescription)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    // MARK: - 錯誤轉換

    private static func mapManagerError(_ error: Error) -> IPCResponse {
        if let managerError = error as? ManagerError {
            switch managerError {
            case .sessionNotFound:
                return IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint, message: error.localizedDescription)
            case .sessionNotRunning:
                return IPCResult.response(IPCResult.processExited, IPCResult.processExitedHint, message: error.localizedDescription)
            case .sessionExists, .invalidName:
                return IPCResult.response(IPCResult.invalidRequest, IPCResult.invalidRequestHint, message: error.localizedDescription)
            }
        }
        return IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: error.localizedDescription)
    }
}
