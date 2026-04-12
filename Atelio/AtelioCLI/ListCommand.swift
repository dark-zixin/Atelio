import ArgumentParser
import Foundation
import AtelioShared

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出所有終端 session"
    )

    func run() throws {
        // list 不需要 name，但 IPCRequest 要求 name 必填
        // 用空字串作為 placeholder，server 端不會用到
        let request = IPCRequest(command: .list, name: "")
        let response = try IPCClient.send(request)

        if response.success {
            // 解析 JSON 陣列格式化輸出
            if let output = response.output,
               let data = output.data(using: .utf8),
               let infos = try? JSONDecoder().decode([SessionInfo].self, from: data) {
                if infos.isEmpty {
                    print("目前沒有任何 session")
                } else {
                    for info in infos {
                        let status = info.isRunning ? "running" : "stopped"
                        let created = info.createdAt ?? "unknown"
                        print("\(info.name)  purpose: \(info.purpose)  status: \(status)  created: \(created)")
                    }
                }
            } else {
                print(response.output ?? "無資料")
            }
        } else {
            fputs(response.message ?? "未知錯誤", stderr)
            fputs("\n", stderr)
            throw ExitCode.failure
        }
    }
}
