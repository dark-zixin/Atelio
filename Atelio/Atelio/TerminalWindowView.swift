import SwiftUI

/// 單個終端視窗：title bar + 真實終端
struct TerminalWindowView: View {
    let session: TerminalSession
    let isFocused: Bool
    let isMaximized: Bool
    let availableModes: [LayoutMode]

    var onSelectLayout: ((LayoutMode) -> Void)?
    var onMinimize: (() -> Void)?
    var onMaximize: (() -> Void)?
    var onClose: (() -> Void)?
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            TerminalTitleBar(
                name: session.name,
                purpose: session.purpose,
                isFocused: isFocused,
                isMaximized: isMaximized,
                availableModes: availableModes,
                onSelectLayout: onSelectLayout,
                onMinimize: onMinimize,
                onMaximize: onMaximize,
                onClose: onClose
            )

            TerminalViewWrapper(session: session)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
                .background(Color.black)
                .onTapGesture {
                    onTap?()
                }
        }
    }
}
