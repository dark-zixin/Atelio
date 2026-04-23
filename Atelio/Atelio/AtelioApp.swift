import SwiftUI
import AtelioShared

@main
struct AtelioApp: App {
    @State private var manager = TerminalManager()
    @State private var ipcServer: IPCServer?

    /// 進行中 dispatch/wait 計數（供 CommandGroup 判斷是否 disable 字體快捷鍵）
    @StateObject private var dispatchActivity = DispatchActivity()

    init() {
        // 忽略 SIGPIPE：client 斷線時 write socket 會收到 SIGPIPE，
        // 不處理的話會直接殺掉 App。忽略後 write 回傳 -1 + EPIPE，
        // 由 IPCFraming.writeMessage 的錯誤處理接住。
        signal(SIGPIPE, SIG_IGN)

        // Bootstrap：確保 ~/.atelio/ 結構完整。必須在 AtelioConfig.load() /
        // debugLog / IPCServer.start 之前，因為後續寫入點皆相信目錄已建立
        // （僅 debugLog 保留 defensive mkdir 作為 bootstrap 失敗時的保險）。
        //
        // bin/ symlink 與 notify.sh 由 hook 機制使用：
        // - ~/.atelio/bin/atelio → 當前 bundle 內 AtelioCLI（每次啟動 force update，
        //   解決 debug build DerivedData 路徑漂移、release App 移位等情況）
        // - ~/.atelio/notify.sh → 用 AtelioPaths.notifyScriptTemplate 寫入，根據第 2
        //   行 marker 比對：marker 在 → 視為 Atelio 自管可覆寫；marker 不在 → 視為
        //   使用者接管不動
        AtelioPaths.ensureRoot()
        AtelioPaths.ensureBin()
        let cliBinaryURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/AtelioCLI")
        AtelioPaths.updateCLISymlink(target: cliBinaryURL)
        AtelioPaths.ensureNotifyScript(template: AtelioPaths.notifyScriptTemplate)

        // 載入全域設定（AI CLI 白名單、字體大小等）。必須在 TerminalManager /
        // IPCServer 使用前完成，以便後續 session init 時能讀到正確的字體大小
        // 與 marker 白名單。
        AtelioConfig.load()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .onAppear {
                    startIPCServer()
                }
        }
        .commands {
            // 字體大小調整：放在檢視選單群組，不覆蓋既有 commands
            FontSizeCommands(dispatchActivity: dispatchActivity)
        }
    }

    private func startIPCServer() {
        guard ipcServer == nil else { return }
        let server = IPCServer(manager: manager, dispatchActivity: dispatchActivity)
        do {
            try server.start()
            ipcServer = server
        } catch {
            print("IPC server 啟動失敗: \(error.localizedDescription)")
        }
    }
}

/// 字體大小 Commands：拆成獨立 struct 以便 `@ObservedObject` 能正確觸發重繪
///
/// Commands 內嵌在 `.commands { ... }` 裡，需在狀態變化時重新 evaluate
/// `.disabled(...)`。用 `@ObservedObject` 讓 `DispatchActivity` 的
/// `@Published` 變動能驅動這個 struct 的 body。
private struct FontSizeCommands: Commands {
    @ObservedObject var dispatchActivity: DispatchActivity

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            let isDispatching = dispatchActivity.activeDispatchCount > 0

            Button("放大文字") {
                AtelioConfig.setFontSize(AtelioConfig.fontSize + 1)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(isDispatching)

            Button("縮小文字") {
                AtelioConfig.setFontSize(AtelioConfig.fontSize - 1)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(isDispatching)

            Button("重設文字大小") {
                AtelioConfig.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(isDispatching)
        }
    }
}
