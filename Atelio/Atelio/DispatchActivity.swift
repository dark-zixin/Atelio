import Foundation
import SwiftUI
import Combine

/// 進行中 dispatch/wait 計數，供 SwiftUI menu 判斷是否應 disable 字體快捷鍵
///
/// 用 `ObservableObject` + `@Published` 而非 `@Observable`，是因為要維持
/// 跟現有 `TerminalManager`（`@Observable` / `@Bindable`）並行可注入，
/// 同時這個類只給 SwiftUI 用，不會出現在 IPCServer 的核心路徑。
///
/// 執行緒約定：所有 `begin()` / `end()` 呼叫必須在 main thread
/// （由 IPCServer 的 handler 透過 `DispatchQueue.main.async` 排程）。
/// `@Published` 在 main thread 更新，SwiftUI 讀取也在 main thread，
/// 因此不需要額外鎖。
final class DispatchActivity: ObservableObject {
    /// 目前進行中的 dispatch / wait 數量
    @Published private(set) var activeDispatchCount: Int = 0

    /// 進入一次 dispatch/wait（+1），必須在 main thread 呼叫
    func begin() {
        dispatchPrecondition(condition: .onQueue(.main))
        activeDispatchCount += 1
        AtelioConfig.debugLog("dispatch_activity_begin", ["count": activeDispatchCount])
    }

    /// 離開一次 dispatch/wait（-1），必須在 main thread 呼叫
    ///
    /// Debug：若 count 已為 0 表示 begin/end 配對出錯，立刻 `assertionFailure` 定位 bug。
    /// Release：靜默保護避免變負（仍 log underflow 事件，便於回溯）。
    func end() {
        dispatchPrecondition(condition: .onQueue(.main))
        if activeDispatchCount <= 0 {
            assertionFailure("DispatchActivity.end() underflow：begin/end 配對不對稱")
            AtelioConfig.debugLog("dispatch_activity_underflow", [:])
            return
        }
        activeDispatchCount -= 1
        AtelioConfig.debugLog("dispatch_activity_end", ["count": activeDispatchCount])
    }
}
