import Foundation

/// 終端 session 的狀態資訊
public struct SessionInfo: Codable {
    public let name: String
    public let isRunning: Bool
    public let pid: Int32?
    public let workingDirectory: String?

    public init(name: String, isRunning: Bool, pid: Int32?, workingDirectory: String?) {
        self.name = name
        self.isRunning = isRunning
        self.pid = pid
        self.workingDirectory = workingDirectory
    }
}
