import SwiftUI

@main
struct AtelioApp: App {
    @State private var manager = TerminalManager()
    @State private var ipcServer: IPCServer?

    init() {
        // 忽略 SIGPIPE：client 斷線時 write socket 會收到 SIGPIPE，
        // 不處理的話會直接殺掉 App。忽略後 write 回傳 -1 + EPIPE，
        // 由 IPCFraming.writeMessage 的錯誤處理接住。
        signal(SIGPIPE, SIG_IGN)

        // 載入全域設定（AI CLI 白名單等）。必須在 TerminalManager / IPCServer
        // 使用前完成，以便後續 session init 時能正確判斷是否啟用 marker。
        AtelioConfig.load()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .onAppear {
                    startIPCServer()
                }
        }
    }

    private func startIPCServer() {
        guard ipcServer == nil else { return }
        let server = IPCServer(manager: manager)
        do {
            try server.start()
            ipcServer = server
        } catch {
            print("IPC server 啟動失敗: \(error.localizedDescription)")
        }
    }
}
