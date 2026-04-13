import Foundation

/// 終端視窗的顯示狀態
enum WindowDisplayState {
    case normal     // 在 layout 中正常顯示
    case minimized  // 縮小到底部列
    case maximized  // 佔滿整個畫面
}

/// 管理所有終端視窗的 layout 和顯示狀態
@Observable
class WorkspaceState {

    /// 當前的 layout 模式
    var layoutMode: LayoutMode = .equal

    /// 主位終端的 name（在 topMain/leftMain 模式中佔大格的那個）
    var mainTerminalName: String?

    /// 每個終端的顯示狀態（key = terminal name）
    var displayStates: [String: WindowDisplayState] = [:]

    /// 當前焦點終端的 name
    var focusedTerminalName: String?

    // MARK: - 查詢

    /// 取得某個終端的顯示狀態
    func displayState(for name: String) -> WindowDisplayState {
        displayStates[name] ?? .normal
    }

    /// 正常顯示中的終端 names（排除最小化的）
    func normalTerminalNames(from allNames: [String]) -> [String] {
        allNames.filter { displayState(for: $0) == .normal }
    }

    /// 最小化的終端 names
    func minimizedTerminalNames(from allNames: [String]) -> [String] {
        allNames.filter { displayState(for: $0) == .minimized }
    }

    /// 是否有終端處於最大化狀態
    var maximizedTerminalName: String? {
        displayStates.first { $0.value == .maximized }?.key
    }

    // MARK: - 操作

    /// 最小化終端
    func minimize(_ name: String) {
        displayStates[name] = .minimized
        // 如果最小化的是焦點終端，轉移焦點
        if focusedTerminalName == name {
            focusedTerminalName = nil
        }
        // 如果最小化的是主位，清除主位
        if mainTerminalName == name {
            mainTerminalName = nil
        }
    }

    /// 最大化前被暫時縮小的終端（還原時恢復）
    private var autoMinimizedNames: Set<String> = []

    /// 最大化終端（或從最大化還原）
    ///
    /// 最大化時，其他正常顯示的終端自動移到底部縮小列。
    /// 還原時，被自動縮小的終端一起恢復。
    func toggleMaximize(_ name: String) {
        if displayStates[name] == .maximized {
            // 還原：自己變 normal，被自動縮小的也恢復
            displayStates[name] = .normal
            for autoName in autoMinimizedNames {
                displayStates[autoName] = .normal
            }
            autoMinimizedNames.removeAll()
        } else {
            // 最大化：把其他 normal 的暫時縮小
            autoMinimizedNames.removeAll()
            for (key, state) in displayStates where key != name {
                if state == .normal {
                    displayStates[key] = .minimized
                    autoMinimizedNames.insert(key)
                }
            }
            displayStates[name] = .maximized
            focusedTerminalName = name
        }
    }

    /// 從底部列恢復終端
    func restore(_ name: String) {
        // 如果目前有最大化的終端，恢復這個意味著退出最大化
        if let maxName = maximizedTerminalName {
            // 還原最大化的終端
            displayStates[maxName] = .normal
            // 還原所有被自動縮小的
            for autoName in autoMinimizedNames {
                displayStates[autoName] = .normal
            }
            autoMinimizedNames.removeAll()
            // 被點擊的終端也要設回 normal（可能是手動 minimized 的）
            displayStates[name] = .normal
            // 焦點給被恢復的終端
            focusedTerminalName = name
        } else {
            displayStates[name] = .normal
            focusedTerminalName = name
        }
    }

    /// 選擇 layout 模式，指定終端為主位
    func selectLayout(mode: LayoutMode, mainTerminal: String) {
        layoutMode = mode
        mainTerminalName = mainTerminal
        focusedTerminalName = mainTerminal
    }

    /// 移除終端的狀態（關閉時呼叫）
    ///
    /// 如果關閉的是主位終端，layout 切回均分。
    func removeTerminal(_ name: String) {
        displayStates.removeValue(forKey: name)
        if mainTerminalName == name {
            mainTerminalName = nil
            layoutMode = .equal
        }
        if focusedTerminalName == name {
            focusedTerminalName = nil
        }
    }

    /// 註冊新終端（預設 normal 狀態）
    func registerTerminal(_ name: String) {
        if displayStates[name] == nil {
            displayStates[name] = .normal
        }
    }
}
