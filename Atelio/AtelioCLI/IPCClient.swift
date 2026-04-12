import Foundation
import AtelioShared

/// IPC client，連線到 Atelio App 的 Unix socket
enum IPCClient {

    /// 送出請求並等待回應
    static func send(_ request: IPCRequest) throws -> IPCResponse {
        let socketPath = "/tmp/atelio.sock"

        // 建立 socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.connectionFailed
        }
        defer { close(fd) }

        // 連線到 server
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectionFailed
        }

        // 送出請求
        let requestData = try IPCFraming.encode(request)
        try IPCFraming.writeMessage(requestData, to: fd)

        // 讀取回應
        let responseData = try IPCFraming.readMessage(from: fd)
        let response = try JSONDecoder().decode(IPCResponse.self, from: responseData)

        return response
    }
}
