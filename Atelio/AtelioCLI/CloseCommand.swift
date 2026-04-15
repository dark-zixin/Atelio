import ArgumentParser
import Foundation
import AtelioShared

struct CloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "關閉終端 session（作業中時需二次確認）"
    )

    @Argument(help: "Session 名稱")
    var name: String

    @Option(name: .long, help: "確認關閉的 key（作業中時由第一次 close 回傳）")
    var confirm: String?

    func run() throws {
        let request = IPCRequest(command: .close, name: name, confirmKey: confirm)
        let response = try IPCClient.send(request)

        if response.result == IPCResult.ok {
            print(response.message ?? "OK")
        } else {
            fputs(response.message ?? response.resultHint, stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
