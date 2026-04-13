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

        if response.success {
            if let output = response.output {
                print(output)
            }
            if response.timeout == true {
                fputs("（超時）\n", stderr)
                throw ExitCode(1)
            }
        } else {
            fputs(response.message ?? "未知錯誤", stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
