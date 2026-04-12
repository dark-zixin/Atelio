import ArgumentParser
import Foundation
import AtelioShared

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "查詢終端 session 狀態"
    )

    @Argument(help: "Session 名稱")
    var name: String

    func run() throws {
        let request = IPCRequest(command: .status, name: name)
        let response = try IPCClient.send(request)

        if response.success {
            print(response.message ?? "OK")
        } else {
            fputs(response.message ?? "未知錯誤", stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
