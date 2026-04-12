import ArgumentParser
import Foundation
import AtelioShared

struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "開啟新的終端 session"
    )

    @Argument(help: "Session 名稱")
    var name: String

    @Option(name: .long, help: "工作目錄")
    var dir: String = "/tmp"

    @Option(name: .long, help: "啟動指令")
    var cmd: String = "/bin/zsh"

    func run() throws {
        let request = IPCRequest(command: .open, name: name, dir: dir, cmd: cmd)
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
