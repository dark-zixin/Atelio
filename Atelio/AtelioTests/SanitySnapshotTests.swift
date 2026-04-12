import XCTest
import SwiftUI
import SnapshotTesting
@testable import Atelio

final class SanitySnapshotTests: XCTestCase {
    // 基本 snapshot 測試，確認環境正常
    func testSimpleView() {
        let view = VStack {
            Text("Atelio Snapshot Test")
                .font(.title)
                .foregroundStyle(.white)
            Text("環境驗證成功")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(width: 400, height: 120)
        .background(Color.black)

        assertSnapshot(
            of: NSHostingController(rootView: view),
            as: .image(size: CGSize(width: 400, height: 120))
        )
    }
}
