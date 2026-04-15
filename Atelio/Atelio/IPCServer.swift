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
            let errorResponse = IPCResponse(success: false, message: error.localizedDescription)
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
        content += "success: \(response.success)\n"
        content += "timeout: \(response.timeout ?? false)\n"
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
        }
    }

    /// 驗證 callerPID 是否有權操作 session（dispatch/close/wait 共用）
    /// 回傳 nil 表示通過，否則回傳錯誤訊息
    private func verifyOwner(session: TerminalSession, callerPID: Int32?, command: String) -> String? {
        guard let callerPID = callerPID else { return nil }
        if let owner = session.ownerPID {
            if kill(owner, 0) != 0 {
                // owner 已死 → session 鎖定，只有 screen 可用
                return "此 session 的擁有者已斷開（owner=\(owner)），無法 \(command)（請從 UI 關閉或用 screen 查看）"
            } else if owner != callerPID {
                return "此 session 由其他程序擁有（owner=\(owner)），無權 \(command)"
            }
        }
        return nil
    }

    private func handleOpen(_ request: IPCRequest) -> IPCResponse {
        let dir = request.dir ?? "/tmp"
        let cmd = request.cmd ?? "/bin/zsh"
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let purpose = request.purpose ?? ""
                let session = try self.manager.open(name: request.name, purpose: purpose, directory: dir, command: cmd)
                // open 時就記錄 ownerPID，session 從建立那刻起就有 owner
                session.ownerPID = request.callerPID
                // 等待 shell 初始 prompt 出現才回傳（確保 session 就緒）
                session.waitForReady(timeout: 5) { [weak self] ready in
                    if ready {
                        response = IPCResponse(success: true, message: "已開啟 session '\(session.name)'")
                    } else if session.isRunning {
                        // process 還活著但就緒超時（可能是 TUI 初始化慢）
                        response = IPCResponse(success: true, message: "已開啟 session '\(session.name)'（就緒超時）")
                    } else {
                        // process 已死亡（cd 失敗、exec 失敗等）→ 移除並回報失敗
                        self?.manager.sessions.removeValue(forKey: request.name)
                        response = IPCResponse(success: false, message: "session '\(request.name)' 啟動失敗（process 已結束）")
                    }
                    semaphore.signal()
                }
                return
            } catch {
                response = IPCResponse(success: false, message: error.localizedDescription)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleDispatch(_ request: IPCRequest) -> IPCResponse {
        guard let text = request.text else {
            return IPCResponse(success: false, message: "缺少 text 參數")
        }
        let timeout = request.timeout ?? 60
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                // PPID owner 驗證
                if let session = self.manager.sessions[request.name],
                   let error = self.verifyOwner(session: session, callerPID: request.callerPID, command: "dispatch") {
                    response = IPCResponse(success: false, message: error)
                    semaphore.signal()
                    return
                }

                try self.manager.dispatch(name: request.name, text: text, timeout: timeout) { output, completed in
                    response = IPCResponse(success: true, output: output, timeout: !completed)
                    semaphore.signal()
                }
            } catch {
                response = IPCResponse(success: false, message: error.localizedDescription)
                semaphore.signal()
            }
        }

        // 等待完成偵測（加安全邊際）
        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout + 10))
        if waitResult == .timedOut {
            response = IPCResponse(success: false, message: "IPC 超時")
        }
        return response
    }

    private func handleStatus(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let info = try self.manager.status(name: request.name)
                let json = try JSONEncoder().encode(info)
                let infoStr = String(data: json, encoding: .utf8) ?? "{}"
                response = IPCResponse(success: true, message: infoStr)
            } catch {
                response = IPCResponse(success: false, message: error.localizedDescription)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleClose(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            // PPID owner 驗證
            if let session = self.manager.sessions[request.name],
               let error = self.verifyOwner(session: session, callerPID: request.callerPID, command: "close") {
                response = IPCResponse(success: false, message: error)
                semaphore.signal()
                return
            }
            self.manager.close(name: request.name, confirmKey: request.confirmKey) { result in
                response = result
                semaphore.signal()
            }
        }

        // close 的 busy 檢查需要 2 秒，加安全邊際
        let waitResult = semaphore.wait(timeout: .now() + .seconds(10))
        if waitResult == .timedOut {
            response = IPCResponse(success: false, message: "close 操作超時")
        }
        return response
    }

    private func handleScreen(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let content = try self.manager.screen(name: request.name)
                response = IPCResponse(success: true, output: content)
            } catch {
                response = IPCResponse(success: false, message: error.localizedDescription)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }

    private func handleWait(_ request: IPCRequest) -> IPCResponse {
        let timeout = request.timeout ?? 60
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                // PPID owner 驗證
                if let session = self.manager.sessions[request.name],
                   let error = self.verifyOwner(session: session, callerPID: request.callerPID, command: "wait") {
                    response = IPCResponse(success: false, message: error)
                    semaphore.signal()
                    return
                }

                try self.manager.wait(name: request.name, timeout: timeout) { output, completed in
                    response = IPCResponse(success: true, output: output, timeout: !completed)
                    semaphore.signal()
                }
            } catch {
                response = IPCResponse(success: false, message: error.localizedDescription)
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeout + 10))
        if waitResult == .timedOut {
            response = IPCResponse(success: false, message: "IPC 超時")
        }
        return response
    }

    private func handleList(_ request: IPCRequest) -> IPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response = IPCResponse(success: false, message: "未知錯誤")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                response = IPCResponse(success: false, message: "Server 已關閉")
                semaphore.signal()
                return
            }
            do {
                let infos = self.manager.list()
                let json = try JSONEncoder().encode(infos)
                let jsonStr = String(data: json, encoding: .utf8) ?? "[]"
                response = IPCResponse(success: true, output: jsonStr)
            } catch {
                response = IPCResponse(success: false, message: error.localizedDescription)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return response
    }
}
