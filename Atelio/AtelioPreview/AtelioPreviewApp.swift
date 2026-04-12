import SwiftUI

@main
struct AtelioPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            PreviewContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
    }
}
