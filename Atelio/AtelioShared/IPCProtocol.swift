import Foundation

// MARK: - 請求

public struct IPCRequest: Codable {
    public enum Command: String, Codable {
        case open, dispatch, status, close, screen, wait, list
    }

    public let command: Command
    public let name: String
    public var dir: String?
    public var cmd: String?
    public var text: String?
    public var timeout: Int?
    public var confirmKey: String?
    public var purpose: String?
    public var callerPID: Int32?

    public init(command: Command, name: String, dir: String? = nil, cmd: String? = nil, text: String? = nil, timeout: Int? = nil, confirmKey: String? = nil, purpose: String? = nil, callerPID: Int32? = nil) {
        self.command = command
        self.name = name
        self.dir = dir
        self.cmd = cmd
        self.text = text
        self.timeout = timeout
        self.confirmKey = confirmKey
        self.purpose = purpose
        self.callerPID = callerPID
    }
}

// MARK: - 回應

public struct IPCResponse: Codable {
    /// 回傳原因（主要判斷依據）
    public let result: String
    /// 自然語言提示，解釋 result 的含義和建議行動（給 AI 消費端）
    public let resultHint: String
    /// 終端畫面內容
    public var output: String?
    /// 錯誤訊息或補充資訊
    public var message: String?

    public init(result: String, resultHint: String, output: String? = nil, message: String? = nil) {
        self.result = result
        self.resultHint = resultHint
        self.output = output
        self.message = message
    }
}

/// IPC 回應的 result 枚舉值和對應的 hint
public enum IPCResult {
    // dispatch/wait 正常回傳
    public static let quietWindowMet = "quiet_window_met"
    public static let quietWindowMetHint = "No visible screen changes detected for the quiet window period. This does not mean the task is complete — check the output to determine next steps."

    public static let deadlineReached = "deadline_reached"
    public static let deadlineReachedHint = "The specified wait time has been reached. The session may still be active — check the output to decide whether to wait again, check screen, or send a new command."

    // session 生命週期
    public static let processExited = "process_exited"
    public static let processExitedHint = "The terminal process has exited. This session can no longer accept dispatch or wait commands. Open a new session if needed."

    public static let sessionClosed = "session_closed"
    public static let sessionClosedHint = "The session has been closed. Do not retry this session — open a new one if needed."

    // 權限與查找
    public static let ownerMismatch = "owner_mismatch"
    public static let ownerMismatchHint = "This session is owned by another process. Only the screen command is available for read-only access."

    public static let sessionNotFound = "session_not_found"
    public static let sessionNotFoundHint = "The specified session does not exist. Verify the session name or open a new session."

    // 請求層級
    public static let invalidRequest = "invalid_request"
    public static let invalidRequestHint = "The request is missing required parameters. Fix the request and retry."

    public static let internalError = "internal_error"
    public static let internalErrorHint = "An internal server error occurred. Use screen or status to check the session state before retrying."

    // 非 dispatch/wait 的一般成功
    public static let ok = "ok"
    public static let okHint = "The operation completed successfully."

    /// 快速建構 IPCResponse
    public static func response(_ result: String, _ hint: String, output: String? = nil, message: String? = nil) -> IPCResponse {
        IPCResponse(result: result, resultHint: hint, output: output, message: message)
    }
}

// MARK: - 訊息框架（長度前綴 + JSON）

public enum IPCFraming {

    /// 將 Codable 物件編碼為帶長度前綴的 Data
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// 從 file descriptor 讀取一則完整訊息
    public static func readMessage(from fd: Int32) throws -> Data {
        // 讀取 4 bytes 長度前綴
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let headerRead = readFully(fd: fd, buffer: &lengthBytes, count: 4)
        guard headerRead == 4 else {
            throw IPCError.connectionClosed
        }

        let length = Int(UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16 | UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3]))
        guard length > 0, length < 10_000_000 else {
            throw IPCError.invalidMessage
        }

        // 讀取 JSON payload
        var payload = [UInt8](repeating: 0, count: length)
        let bodyRead = readFully(fd: fd, buffer: &payload, count: length)
        guard bodyRead == length else {
            throw IPCError.connectionClosed
        }

        return Data(payload)
    }

    /// 將帶長度前綴的 Data 寫入 file descriptor
    public static func writeMessage(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, base.advanced(by: offset), remaining)
                if written <= 0 {
                    throw IPCError.writeFailed
                }
                offset += written
                remaining -= written
            }
        }
    }

    /// 確保完整讀取指定數量的 bytes
    private static func readFully(fd: Int32, buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        var totalRead = 0
        while totalRead < count {
            let bytesRead = read(fd, buffer.advanced(by: totalRead), count - totalRead)
            if bytesRead <= 0 { break }
            totalRead += bytesRead
        }
        return totalRead
    }
}

// MARK: - 錯誤

public enum IPCError: Error, LocalizedError {
    case connectionClosed
    case invalidMessage
    case writeFailed
    case connectionFailed

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: return "連線已關閉"
        case .invalidMessage: return "無效的訊息格式"
        case .writeFailed: return "寫入失敗"
        case .connectionFailed: return "無法連線到 Atelio App"
        }
    }
}
