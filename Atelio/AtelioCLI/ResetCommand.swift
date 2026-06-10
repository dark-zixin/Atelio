import ArgumentParser
import Foundation
import AtelioShared

struct ResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "強制結束卡住的 turn，讓 session 回到 idle"
    )

    @Argument(help: "Session 名稱")
    var name: String

    func run() throws {
        let request = IPCRequest(command: .reset, name: name)
        let response = try IPCClient.send(request)

        // 統一狀態行（stderr）：與 dispatch/wait 相同，讓呼叫端程式化判讀
        // （穩定閘拒絕時 result 為 turn_in_progress）
        fputs("atelio-result: \(response.result)\n", stderr)

        switch response.result {
        case IPCResult.ok:
            print(response.message ?? "OK")
        default:
            fputs(response.message ?? response.resultHint, stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
