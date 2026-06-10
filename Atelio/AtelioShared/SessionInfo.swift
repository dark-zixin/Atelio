import Foundation

/// 終端 session 的狀態資訊
public struct SessionInfo: Codable {
    public let name: String
    public let purpose: String
    public let isRunning: Bool
    /// session 即時狀態：busy / idle / unowned / exited（TerminalSession.Status 的字串值）
    public let status: String?
    public let pid: Int32?
    public let workingDirectory: String?
    public let createdAt: String?

    public init(name: String, purpose: String, isRunning: Bool, status: String? = nil, pid: Int32?, workingDirectory: String?, createdAt: String? = nil) {
        self.name = name
        self.purpose = purpose
        self.isRunning = isRunning
        self.status = status
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
    }
}
