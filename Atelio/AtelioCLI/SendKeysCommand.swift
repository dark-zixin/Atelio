import ArgumentParser
import Foundation
import AtelioShared

struct SendKeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-keys",
        abstract: "送 raw keystroke 到 session PTY（不包 bracketed paste、不補 \\r）",
        discussion: """
        用於操作 AI CLI 的 TUI 互動（例如 approval prompt）。

        支援的 key name（大小寫不敏感）：
          enter, return         → Enter
          esc, escape           → ESC（取消 approval 常用）
          tab                   → Tab
          space                 → Space
          bspace, backspace     → Backspace
          up, down, left, right → 方向鍵
          c-<letter>            → Ctrl-<letter>（例 c-c / c-d / c-z）
          任意單字元            → 原字元（例 y / n / 1 / 2 / 3 / p）

        範例：
          atelio send-keys mysession esc
          atelio send-keys mysession 3
          atelio send-keys mysession c-c
        """
    )

    @Argument(help: "Session 名稱")
    var name: String

    @Argument(help: "Key name（見上方描述）")
    var key: String

    func run() throws {
        let request = IPCRequest(command: .sendKeys, name: name, text: key)
        let response = try IPCClient.send(request)
        if response.result == IPCResult.ok {
            if let msg = response.message {
                print(msg)
            }
        } else {
            fputs((response.message ?? response.resultHint) + "\n", stderr)
            throw ExitCode.failure
        }
    }
}
