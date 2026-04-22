import Foundation
import AtelioShared

/// IPC client，連線到 Atelio App 的 Unix socket
enum IPCClient {

    /// 取得指定 PID 的父進程 PID（透過 sysctl）
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// 取得呼叫端的祖父進程 PID（AI process 的 PID）
    /// CLI 被 shell fork → shell 被 AI fork，所以 GPPID = AI 的 PID
    private static func callerIdentity() -> Int32 {
        let ppid = getppid()
        return parentPID(of: ppid) ?? ppid
    }

    /// 送出請求並等待回應
    static func send(_ request: IPCRequest) throws -> IPCResponse {
        // 自動注入呼叫端的祖父進程 PID（AI process 的 PID，用於 owner 驗證）
        var request = request
        request.callerPID = callerIdentity()

        let socketPath = AtelioPaths.socketPath

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
