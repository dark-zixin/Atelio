import SwiftUI

/// Layout 模式選擇器（下拉選單）
struct LayoutPickerView: View {
    let availableModes: [LayoutMode]
    let onSelect: (LayoutMode) -> Void

    var body: some View {
        Menu {
            ForEach(availableModes) { mode in
                Button(mode.displayName) {
                    onSelect(mode)
                }
            }
        } label: {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }
}
