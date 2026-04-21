import ArgumentParser
import Foundation
import AtelioShared

struct PeekCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "peek",
        abstract: "診斷：讀取 session PTY 的 foreground process（用於驗證 marker 動態偵測可行性）"
    )

    @Argument(help: "Session 名稱")
    var name: String

    func run() throws {
        let request = IPCRequest(command: .peek, name: name)
        let response = try IPCClient.send(request)

        if response.result == IPCResult.ok {
            if let output = response.output {
                print(output)
            }
        } else {
            fputs(response.message ?? response.resultHint, stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
