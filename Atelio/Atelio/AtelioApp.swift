import SwiftUI

@main
struct AtelioApp: App {
    @State private var manager = TerminalManager()
    @State private var ipcServer: IPCServer?

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
