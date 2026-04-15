import ArgumentParser
import Foundation
import AtelioShared

struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "發送 hook 事件通知給 Atelio App"
    )

    @Argument(help: "事件名稱（turn_start / turn_end）")
    var event: String

    func run() throws {
        // 從環境變數讀 session 名稱
        guard let session = ProcessInfo.processInfo.environment["ATELIO_SESSION"],
              !session.isEmpty else {
            // 非 Atelio session，靜默退出
            return
        }

        let request = IPCRequest(command: .notify, name: session, text: event)
        do {
            let response = try IPCClient.send(request)
            if response.result != IPCResult.ok {
                // 靜默失敗 — hook 不應影響 AI CLI
            }
        } catch {
            // 靜默失敗
        }
    }
}
