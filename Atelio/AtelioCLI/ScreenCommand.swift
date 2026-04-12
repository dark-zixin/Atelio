import ArgumentParser
import Foundation
import AtelioShared

struct ScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "讀取終端目前的可見畫面"
    )

    @Argument(help: "Session 名稱")
    var name: String

    func run() throws {
        let request = IPCRequest(command: .screen, name: name)
        let response = try IPCClient.send(request)

        if response.success {
            if let output = response.output {
                print(output)
            }
        } else {
            fputs(response.message ?? "未知錯誤", stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
