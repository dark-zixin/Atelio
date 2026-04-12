import Foundation
import Observation
import AtelioShared

/// 管理所有終端 session
@Observable
class TerminalManager {

    /// 以 name 為 key 的 session 字典
    var sessions: [String: TerminalSession] = [:]

    // MARK: - 操作

    /// 開啟新的終端 session
    func open(name: String, directory: String, command: String) throws -> TerminalSession {
        guard sessions[name] == nil else {
            throw ManagerError.sessionExists(name)
        }

        let session = TerminalSession(name: name, directory: directory, command: command)
        sessions[name] = session
        return session
    }

    /// 對指定 session 派發指令
    func dispatch(name: String, text: String, timeout: Int, completion: @escaping (String, Bool) -> Void) throws {
        guard let session = sessions[name] else {
            throw ManagerError.sessionNotFound(name)
        }
        guard session.isRunning else {
            throw ManagerError.sessionNotRunning(name)
        }
        session.dispatch(text: text, timeout: timeout, completion: completion)
    }

    /// 取得指定 session 的狀態
    func status(name: String) throws -> SessionInfo {
        guard let session = sessions[name] else {
            throw ManagerError.sessionNotFound(name)
        }
        return session.sessionInfo()
    }

    /// 等待指定 session 的畫面穩定（不送文字）
    func wait(name: String, timeout: Int, completion: @escaping (String, Bool) -> Void) throws {
        guard let session = sessions[name] else {
            throw ManagerError.sessionNotFound(name)
        }
        guard session.isRunning else {
            throw ManagerError.sessionNotRunning(name)
        }
        session.wait(timeout: timeout, completion: completion)
    }

    /// 讀取指定 session 的終端畫面
    func screen(name: String) throws -> String {
        guard let session = sessions[name] else {
            throw ManagerError.sessionNotFound(name)
        }
        return session.readScreen()
    }

    /// 關閉指定 session（兩段式：busy 時需確認 key）
    func close(name: String, confirmKey: String?, completion: @escaping (IPCResponse) -> Void) {
        guard let session = sessions[name] else {
            completion(IPCResponse(success: false, message: "找不到 session '\(name)'"))
            return
        }

        // 如果有 confirmKey，驗證後直接關閉
        if let key = confirmKey {
            if session.validateCloseKey(key) {
                session.forceClose()
                sessions.removeValue(forKey: name)
                completion(IPCResponse(success: true, message: "已關閉 session '\(name)'"))
            } else {
                completion(IPCResponse(success: false, message: "確認 key 無效"))
            }
            return
        }

        // 沒有 confirmKey → 檢查是否 busy
        session.checkBusy { [weak self] isBusy in
            guard let self = self else { return }
            if isBusy {
                // busy → 產生 key，要求確認
                let key = session.generateCloseKey()
                completion(IPCResponse(success: false, message: "session 仍在作業中。確認關閉請使用 --confirm \(key)"))
            } else {
                // idle → 直接關閉
                session.forceClose()
                self.sessions.removeValue(forKey: name)
                completion(IPCResponse(success: true, message: "已關閉 session '\(name)'"))
            }
        }
    }
}

// MARK: - 錯誤

enum ManagerError: Error, LocalizedError {
    case sessionExists(String)
    case sessionNotFound(String)
    case sessionNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .sessionExists(let name): return "Session '\(name)' 已存在"
        case .sessionNotFound(let name): return "找不到 session '\(name)'"
        case .sessionNotRunning(let name): return "Session '\(name)' 已停止"
        }
    }
}
