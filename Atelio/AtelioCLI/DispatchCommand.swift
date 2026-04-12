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

        if response.success {
            // 印出指令輸出到 stdout
            if let output = response.output {
                print(output)
            }
            // 如果超時，以非零 exit code 結束
            if response.completed == false {
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
