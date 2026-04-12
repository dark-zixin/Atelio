import Foundation

/// 終端 session 的狀態資訊
public struct SessionInfo: Codable {
    public let name: String
    public let purpose: String
    public let isRunning: Bool
    public let pid: Int32?
    public let workingDirectory: String?
    public let createdAt: String?

    public init(name: String, purpose: String, isRunning: Bool, pid: Int32?, workingDirectory: String?, createdAt: String? = nil) {
        self.name = name
        self.purpose = purpose
        self.isRunning = isRunning
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
    }
}
