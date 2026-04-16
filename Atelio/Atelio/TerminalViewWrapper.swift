import SwiftUI
import SwiftTerm

/// 將 SwiftTerm 的 LocalProcessTerminalView（NSView）包進 SwiftUI
struct TerminalViewWrapper: NSViewRepresentable {

    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        return session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 不需要更新，終端 view 自行管理狀態
    }
}
