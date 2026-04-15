import ArgumentParser
import Foundation
import AtelioShared

struct WaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "等待終端畫面穩定（不送文字）"
    )

    @Argument(help: "Session 名稱")
    var name: String

    @Option(name: .long, help: "超時秒數")
    var timeout: Int = 60

    func run() throws {
        let request = IPCRequest(command: .wait, name: name, timeout: timeout)
        let response = try IPCClient.send(request)

        if let output = response.output {
            print(output)
        }

        switch response.result {
        case IPCResult.quietWindowMet, IPCResult.hookTurnEnded:
            break  // 完成（hash 穩定或 hook 確認）
        case IPCResult.turnInProgress:
            fputs(response.resultHint, stderr)
            fputs("\n", stderr)
            throw ExitCode(1)
        case IPCResult.deadlineReached:
            fputs("（\(response.resultHint)）\n", stderr)
            throw ExitCode(1)
        default:
            fputs(response.message ?? response.resultHint, stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
