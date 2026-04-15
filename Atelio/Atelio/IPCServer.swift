import Foundation
import AtelioShared

/// Unix domain socket server，接收 CLI 指令並路由到 TerminalManager
class IPCServer {

    static let socketPath = "/tmp/atelio.sock"

    /// 暫時的回應 logging 目錄（設為 nil 關閉 logging）
    static var responseLogDir: String? = "/Users/dark/work/macos-apps/atelio/temp_doc/0414_openclaw_denoise_test/raw"

    private let manager: TerminalManager
    private var serverFd: Int32 = -1
    private var isRunning = false

    init(manager: TerminalManager) {
        self.manager = manager
    }

    // MARK: - 啟動與停止

    /// 啟動 IPC server
    func start() throws {
        // 清除舊的 socket 檔案
        unlink(IPCServer.socketPath)

        // 建立 socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw IPCError.connectionFailed
        }

        // 綁定到路徑
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = IPCServer.socketPath.utf8CString
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
        }
    }

    /// 驗證 callerPID 是否有權操作 session（dispatch/close/wait 共用）
    /// 回傳 nil 表示通過，否則回傳 IPCResponse
    private func verifyOwner(session: TerminalSession, callerPID: Int32?, command: String) -> IPCResponse? {
        guard let callerPID = callerPID else { return nil }
        if let owner = session.ownerPID {
            if kill(owner, 0) != 0 {
                // owner 已死 → session 鎖定
                return IPCResult.response(IPCResult.ownerMismatch, IPCResult.ownerMismatchHint,
                    message: "此 session 的擁有者已斷開（owner=\(owner)），無法 \(command)")
            } else if owner != callerPID {
                return IPCResult.response(IPCResult.ownerMismatch, IPCResult.ownerMismatchHint,
                    message: "此 session 由其他程序擁有（owner=\(owner)），無權 \(command)")
            }
        }
        return nil
    }

    private func handleNotify(_ request: IPCRequest) -> IPCResponse {
        let event = request.text ?? "unknown"
        let sessionName = request.name

        // 找到對應 session 並通知（dispatch 到 main thread，因為 terminal 操作必須在 main thread）
        DispatchQueue.main.async { [weak self] in
            guard let session = self?.manager.sessions[sessionName] else { return }
            switch event {
            case "turn_start": session.handleTurnStart()
            case "turn_end": session.handleTurnEnd()
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
        guard let text = request.text else {
            return IPCResult.response(IPCResult.invalidRequest, IPCResult.invalidRequestHint, message: "缺少 text 參數")
        }
        let timeout = request.timeout ?? 60
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                // PPID owner 驗證
                if let session = self.manager.sessions[request.name],
                   let ownerError = self.verifyOwner(session: session, callerPID: request.callerPID, command: "dispatch") {
                    response = ownerError
                    semaphore.signal()
                    return
                }

                let session = self.manager.sessions[request.name]
                try self.manager.dispatch(name: request.name, text: text, timeout: timeout) { output, completed in
                    if completed {
                        if session?.turnEndReceived == true {
                            response = IPCResult.response(IPCResult.hookTurnEnded, IPCResult.hookTurnEndedHint, output: output)
                        } else {
                            if session?.turnActive == true {
                                // hook session + hash 穩定觸發（fallback）
                                session?.appendHookLog("fallback_triggered")
                            }
                            response = IPCResult.response(IPCResult.quietWindowMet, IPCResult.quietWindowMetHint, output: output)
                        }
                    } else {
                        if session?.turnActive == true {
                            // AI 還在工作，不帶 output 省 token
                            response = IPCResult.response(IPCResult.turnInProgress, IPCResult.turnInProgressHint)
                        } else {
                            response = IPCResult.response(IPCResult.deadlineReached, IPCResult.deadlineReachedHint, output: output)
                        }
                    }
                    session?.resetAfterCapture()
                    semaphore.signal()
                }
            } catch {
                // ManagerError 轉成對應的 result
                let r = Self.mapManagerError(error)
                response = r
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout + 10))
        if waitResult == .timedOut {
            response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "IPC 超時（server callback 未回傳）")
        }
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
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                // PPID owner 驗證
                if let session = self.manager.sessions[request.name],
                   let ownerError = self.verifyOwner(session: session, callerPID: request.callerPID, command: "wait") {
                    response = ownerError
                    semaphore.signal()
                    return
                }

                let session = self.manager.sessions[request.name]
                try self.manager.wait(name: request.name, timeout: timeout) { output, completed in
                    if completed {
                        if session?.turnEndReceived == true {
                            response = IPCResult.response(IPCResult.hookTurnEnded, IPCResult.hookTurnEndedHint, output: output)
                        } else {
                            if session?.turnActive == true {
                                session?.appendHookLog("fallback_triggered")
                            }
                            response = IPCResult.response(IPCResult.quietWindowMet, IPCResult.quietWindowMetHint, output: output)
                        }
                    } else {
                        if session?.turnActive == true {
                            response = IPCResult.response(IPCResult.turnInProgress, IPCResult.turnInProgressHint)
                        } else {
                            response = IPCResult.response(IPCResult.deadlineReached, IPCResult.deadlineReachedHint, output: output)
                        }
                    }
                    session?.resetAfterCapture()
                    semaphore.signal()
                }
            } catch {
                response = Self.mapManagerError(error)
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout + 10))
        if waitResult == .timedOut {
            response = IPCResult.response(IPCResult.internalError, IPCResult.internalErrorHint, message: "IPC 超時（server callback 未回傳）")
        }
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

    /// 將 ManagerError 轉成對應的 IPCResponse
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
