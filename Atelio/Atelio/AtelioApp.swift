import SwiftUI
import AtelioShared

@main
struct AtelioApp: App {
    @State private var manager = TerminalManager()
    @State private var ipcServer: IPCServer?

    /// 進行中 dispatch/wait 計數（供 CommandGroup 判斷是否 disable 字體快捷鍵）
    @StateObject private var dispatchActivity = DispatchActivity()

    /// AppDelegate：關掉最後一個視窗時不終止 App，讓 IPC server 與 sessions
    /// 繼續存活。使用者透過 ⌘Q 或選單才真正結束。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 壓掉 AppKit 自動注入但對 terminal 場景無意義的行為：
        // - Dictation / Emoji & Symbols menu item：SwiftTerm 不做自然語言編輯
        // - AutoFill heuristic controller：Ghostty 實測 macOS 26 會對 terminal
        //   造成可感知卡頓（PR ghostty-org/ghostty#8625），關掉背景掃描
        // - Full Screen menu item：由 Atelio 自己決定是否提供全螢幕
        //
        // Writing Tools / AutoFill 的選單項本身由 AppKit 系統級機制每次 popup
        // 前動態重建，SwiftUI / AppDelegate runtime 移除不可靠（業界共識，見
        // Apple Dev Forum #740591），不處理。
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
            "NSAutoFillHeuristicControllerEnabled": false,
            "NSFullScreenMenuItemEverywhere": false,
        ])

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
        // - ~/.atelio/skills/atelio/ → 從 bundle 複製，主 AI 可 symlink 到各自的
        //   skill 目錄取得說明書（每次啟動覆蓋確保版本與 App 一致）
        AtelioPaths.ensureRoot()
        AtelioPaths.ensureBin()
        let cliBinaryURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/AtelioCLI")
        AtelioPaths.updateCLISymlink(target: cliBinaryURL)
        AtelioPaths.ensureNotifyScript(template: AtelioPaths.notifyScriptTemplate)
        let skillSourceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/skills/atelio")
        AtelioPaths.ensureSkill(from: skillSourceURL)

        // 載入全域設定（AI CLI 白名單、字體大小等）。必須在 TerminalManager /
        // IPCServer 使用前完成，以便後續 session init 時能讀到正確的字體大小
        // 與 marker 白名單。
        AtelioConfig.load()
    }

    var body: some Scene {
        Window("Atelio", id: "main") {
            ContentView(manager: manager)
                .onAppear {
                    startIPCServer()
                }
        }
        .commands {
            // 字體大小調整：放在檢視選單群組，不覆蓋既有 commands
            FontSizeCommands(dispatchActivity: dispatchActivity)
            // 說明選單：取代 SwiftUI 預設的 Atelio Help（沒 Help Book 點了會跳
            // 「無說明文件」dialog），改指向自己 render 的 HelpView window
            HelpCommands()
        }

        Window("Atelio 說明", id: "help") {
            HelpView()
                // 雙保險：若 macOS state restoration 只還原 help window，
                // 主 window 的 ContentView.onAppear 不會觸發、IPC 起不來。
                // startIPCServer 有 guard ipcServer == nil 保護，安全呼叫。
                .onAppear {
                    startIPCServer()
                }
        }
        .defaultSize(width: 500, height: 600)
        .windowResizability(.contentSize)
        // Help 是附屬 transient 視窗，不納入系統視窗還原，避免下次啟動
        // 只還原 help 造成「沒 main window、IPC 沒起來」的僵局。
        .restorationBehavior(.disabled)
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

/// 關視窗不退 App：保持 IPC server 與 AI CLI sessions 在背景運行。
///
/// `Window` scene 的 macOS 預設行為是「關掉最後視窗 → App 終止」，對 Atelio
/// 而言等同殺死所有 worker sessions 與 IPC。override 成 false 後，使用者關
/// 視窗只是隱藏 UI，IPC 與 sessions 持續運行；點 Dock icon 可重開視窗，
/// ⌘Q 或選單才真正退出。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// 說明選單 Commands：替換 SwiftUI 預設的 "Atelio Help"（原本 action 是
/// `showHelp:`，Atelio 沒 bundle Help Book、點了只會跳系統 dialog）。
///
/// 新 item 打開 `Atelio 說明` window（由 `HelpView` 實作）。
private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Atelio 說明") {
                openWindow(id: "help")
            }
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
