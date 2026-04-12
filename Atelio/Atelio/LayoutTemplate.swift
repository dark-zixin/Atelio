import Foundation

/// Layout 中每個格子的位置和大小（比例 0.0 ~ 1.0）
struct SlotFrame: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// Layout 模式定義
///
/// 每個模式描述一種排版方式，能根據終端數量自動產生對應的 slots。
/// 模式分為「主位」和「副位」：主位佔大區域，副位均分剩餘空間。
enum LayoutMode: String, CaseIterable, Identifiable {
    /// 所有格子均分
    case equal
    /// 上方一個大格，下方均分
    case topMain
    /// 左側一個大格，右側均分
    case leftMain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equal: return "均分"
        case .topMain: return "上大下小"
        case .leftMain: return "左大右小"
        }
    }
}

/// Layout 模板，根據模式和終端數量產生 slot 位置
struct LayoutTemplate {

    /// 根據模式、終端數量、主位 index 產生每個終端的位置
    ///
    /// - Parameters:
    ///   - mode: 排版模式
    ///   - count: 終端數量
    ///   - mainIndex: 主位終端的 index（用於 topMain/leftMain 模式）
    /// - Returns: 每個終端對應的 SlotFrame 陣列，順序與輸入一致
    static func generateSlots(mode: LayoutMode, count: Int, mainIndex: Int = 0) -> [SlotFrame] {
        guard count > 0 else { return [] }
        if count == 1 { return [SlotFrame(x: 0, y: 0, width: 1, height: 1)] }

        // 產生「模板位置」（index 0 = 主位）
        let templateSlots: [SlotFrame]
        switch mode {
        case .equal:
            templateSlots = generateEqualSlots(count: count)
        case .topMain:
            templateSlots = generateTopMainSlots(count: count)
        case .leftMain:
            templateSlots = generateLeftMainSlots(count: count)
        }

        // 如果 mainIndex != 0，交換主位和指定位置
        // 讓被點的終端佔主位，但保持其他順序不變
        guard mainIndex > 0 && mainIndex < count else { return templateSlots }
        var result = templateSlots
        result.swapAt(0, mainIndex)
        return result
    }

    // MARK: - 均分模式

    /// 自動計算行列數，盡量接近正方形
    private static func generateEqualSlots(count: Int) -> [SlotFrame] {
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellHeight = 1.0 / CGFloat(rows)

        var slots: [SlotFrame] = []
        for i in 0..<count {
            let row = i / cols
            let col = i % cols

            // 最後一列可能不滿，置中或靠左
            let itemsInRow = (row == rows - 1) ? (count - row * cols) : cols
            let rowCellWidth = 1.0 / CGFloat(itemsInRow)
            let colInRow = (row == rows - 1) ? (i - row * cols) : col

            slots.append(SlotFrame(
                x: CGFloat(colInRow) * rowCellWidth,
                y: CGFloat(row) * cellHeight,
                width: rowCellWidth,
                height: cellHeight
            ))
        }
        return slots
    }

    // MARK: - 上大下小模式

    /// 主位佔上方 60%，副位均分下方 40%
    private static func generateTopMainSlots(count: Int) -> [SlotFrame] {
        let mainRatio: CGFloat = 0.6
        let subCount = count - 1
        let subWidth = 1.0 / CGFloat(subCount)

        var slots: [SlotFrame] = [
            // 主位：上方滿版
            SlotFrame(x: 0, y: 0, width: 1, height: mainRatio)
        ]
        // 副位：下方均分
        for i in 0..<subCount {
            slots.append(SlotFrame(
                x: CGFloat(i) * subWidth,
                y: mainRatio,
                width: subWidth,
                height: 1 - mainRatio
            ))
        }
        return slots
    }

    // MARK: - 左大右小模式

    /// 主位佔左側 60%，副位均分右側 40%
    private static func generateLeftMainSlots(count: Int) -> [SlotFrame] {
        let mainRatio: CGFloat = 0.6
        let subCount = count - 1
        let subHeight = 1.0 / CGFloat(subCount)

        var slots: [SlotFrame] = [
            // 主位：左側滿版
            SlotFrame(x: 0, y: 0, width: mainRatio, height: 1)
        ]
        // 副位：右側均分
        for i in 0..<subCount {
            slots.append(SlotFrame(
                x: mainRatio,
                y: CGFloat(i) * subHeight,
                width: 1 - mainRatio,
                height: subHeight
            ))
        }
        return slots
    }
}
