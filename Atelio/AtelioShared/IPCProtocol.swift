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
    public let success: Bool
    public var message: String?
    public var output: String?
    public var timeout: Bool?

    public init(success: Bool, message: String? = nil, output: String? = nil, timeout: Bool? = nil) {
        self.success = success
        self.message = message
        self.output = output
        self.timeout = timeout
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
