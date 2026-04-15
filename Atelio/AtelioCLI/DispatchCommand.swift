import ArgumentParser
import Foundation
import AtelioShared

struct DispatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dispatch",
        abstract: "送出指令到終端並等待完成"
    )

    @Argument(help: "Session 名稱")
    var name: String

    @Argument(help: "要執行的指令文字")
    var text: String

    @Option(name: .long, help: "超時秒數")
    var timeout: Int = 60

    func run() throws {
        let request = IPCRequest(command: .dispatch, name: name, text: text, timeout: timeout)
        let response = try IPCClient.send(request)

        // 印出 output（如果有）
        if let output = response.output {
            print(output)
        }

        // 根據 result 決定 exit code
        switch response.result {
        case IPCResult.quietWindowMet, IPCResult.hookTurnEnded:
            break  // 完成（hash 穩定或 hook 確認）
        case IPCResult.turnInProgress:
            // AI 還在工作，hint 已在 output 位置（無 output）
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
