import Foundation
import Observation
import AtelioShared

/// 管理所有終端 session
@Observable
class TerminalManager {

    /// 以 name 為 key 的 session 字典
    var sessions: [String: TerminalSession] = [:]

    // MARK: - 操作

    /// 列出所有 session 狀態
    func list() -> [SessionInfo] {
        sessions.values
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.sessionInfo() }
    }

    /// 開啟新的終端 session
    func open(name: String, purpose: String, directory: String, command: String) throws -> TerminalSession {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ManagerError.invalidName
        }
        guard sessions[name] == nil else {
            throw ManagerError.sessionExists(name)
        }

        let session = TerminalSession(name: name, purpose: purpose, directory: directory, command: command)
        sessions[name] = session
        return session
    }

    /// 取得指定 session 的狀態
    func status(name: String) throws -> SessionInfo {
        guard let session = sessions[name] else {
            throw ManagerError.sessionNotFound(name)
        }
        return session.sessionInfo()
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
            completion(IPCResult.response(IPCResult.sessionNotFound, IPCResult.sessionNotFoundHint, message: "找不到 session '\(name)'"))
            return
        }

        // 如果有 confirmKey，驗證後直接關閉
        if let key = confirmKey {
            if session.validateCloseKey(key) {
                session.forceClose()
                sessions.removeValue(forKey: name)
                completion(IPCResult.response(IPCResult.ok, IPCResult.okHint, message: "已關閉 session '\(name)'"))
            } else {
                completion(IPCResult.response(IPCResult.invalidRequest, IPCResult.invalidRequestHint, message: "確認 key 無效"))
            }
            return
        }

        // 沒有 confirmKey → 檢查是否 busy
        session.checkBusy { [weak self] isBusy in
            guard let self = self else { return }
            if isBusy {
                // busy → 產生 key，要求確認
                let key = session.generateCloseKey()
                completion(IPCResult.response(IPCResult.invalidRequest, IPCResult.invalidRequestHint, message: "session 仍在作業中。確認關閉請使用 --confirm \(key)"))
            } else {
                // idle → 直接關閉
                session.forceClose()
                self.sessions.removeValue(forKey: name)
                completion(IPCResult.response(IPCResult.ok, IPCResult.okHint, message: "已關閉 session '\(name)'"))
            }
        }
    }
}

// MARK: - 錯誤

enum ManagerError: Error, LocalizedError {
    case sessionExists(String)
    case sessionNotFound(String)
    case sessionNotRunning(String)
    case invalidName

    var errorDescription: String? {
        switch self {
        case .sessionExists(let name): return "Session '\(name)' 已存在"
        case .sessionNotFound(let name): return "找不到 session '\(name)'"
        case .sessionNotRunning(let name): return "Session '\(name)' 已停止"
        case .invalidName: return "Session 名稱不可為空"
        }
    }
}
