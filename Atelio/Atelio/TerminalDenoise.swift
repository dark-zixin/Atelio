import Foundation

/// 終端輸出去噪處理
///
/// 處理流程（pipeline）：
/// 1. L0 — 位元組正規化（NUL/NBSP 移除）
/// 2. L1 — 一定是噪音（待加入）
/// 3. L2 — 幾乎是噪音（待加入）
///
/// 三個 API（dispatch/wait/screen）共用同一個入口。
enum TerminalDenoise {

    /// 去噪主入口
    static func clean(_ text: String) -> String {
        var result = text

        // L0 — 位元組正規化
        result = normalizeBytes(result)

        // L0.5 — 行級 block element 處理（移除 + 含 block element 的行做 trim）
        result = removeBlockElements(result)

        // L1 — 行級清理（rstrip + 空行壓縮）
        result = cleanLines(result)

        // L1.4 — status bar 去重（多組只留最後一組）
        result = deduplicateStatusBar(result)

        return result
    }

    // MARK: - L0 位元組正規化

    /// 移除無意義的字元
    ///
    /// - NUL（0x00）：終端 buffer 中寬字元（CJK）的佔位符
    /// - NBSP（U+00A0）：TUI 渲染副產物
    private static func normalizeBytes(_ text: String) -> String {
        // 快速檢查
        guard text.unicodeScalars.contains(where: { $0.value == 0x00 || $0.value == 0xA0 }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00, 0xA0:
                continue  // 移除
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - L0.5 Block Element 處理

    /// Block Element 字元範圍：U+2500（─）+ U+2580–U+259F（▀▄█░▓ 等）
    ///
    /// 包含 TUI 分隔線、logo 圖案、prompt 框線、進度條等。
    /// 如果一行包含 block element，移除後對該行做 trim（左右都去空白）。
    /// 不包含 block element 的行完全不動（保留程式碼縮排）。
    private static func removeBlockElements(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        let result = lines.map { line -> String in
            guard line.unicodeScalars.contains(where: { isBlockElement($0) }) else {
                return String(line)  // 不含 block element → 不動
            }
            // 移除 block element 字元，然後 trim 整行
            var cleaned = ""
            cleaned.reserveCapacity(line.count)
            for scalar in line.unicodeScalars {
                if !isBlockElement(scalar) {
                    cleaned.unicodeScalars.append(scalar)
                }
            }
            return cleaned.trimmingCharacters(in: .whitespaces)
        }

        return result.joined(separator: "\n")
    }

    /// 判斷是否為 block element 字元
    private static func isBlockElement(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v == 0x2500 || (0x2580 <= v && v <= 0x259F)
    }

    // MARK: - L1 行級清理

    /// rstrip 每行 + 壓縮連續空行為 1 行 + 去除尾端空行
    private static func cleanLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var result: [Substring] = []
        result.reserveCapacity(lines.count)
        var prevEmpty = false

        for line in lines {
            let rstripped = trimRight(line)

            if rstripped.isEmpty {
                // 空行壓縮：連續空行只保留 1 行
                if !prevEmpty {
                    result.append(rstripped)
                }
                prevEmpty = true
            } else {
                prevEmpty = false
                result.append(rstripped)
            }
        }

        // 去除尾端空行
        while result.last?.isEmpty == true {
            result.removeLast()
        }

        return result.joined(separator: "\n")
    }

    /// 移除行尾空白字元（保留行首）
    private static func trimRight(_ s: Substring) -> Substring {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c == " " || c == "\t" {
                end = prev
            } else {
                break
            }
        }
        return s[s.startIndex..<end]
    }

    // MARK: - L1.4 Status Bar 去重

    /// prompt 指示符字元
    private static let promptChars: Set<Character> = ["❯", "›", ">"]

    /// 去除重複的 status bar 區塊，只保留最後一組
    ///
    /// 邏輯：以 prompt 指示符（❯/›/>）為錨點，取上 2 下 3 行作為區塊，
    /// 模糊比對（雙向 LCS 取最小值，閾值 50%）判斷是否重複。
    private static func deduplicateStatusBar(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 找所有 prompt 指示符的位置
        var promptIndices: [Int] = []
        for (i, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if let first = stripped.first, promptChars.contains(first) {
                promptIndices.append(i)
            }
        }

        guard promptIndices.count > 1 else { return text }

        // 建立每個 prompt 的區塊（上 2 下 3）
        struct Block {
            let promptIdx: Int
            let start: Int
            let end: Int  // exclusive
            let normalized: String
        }

        let blocks: [Block] = promptIndices.map { idx in
            let start = max(0, idx - 2)
            let end = min(lines.count, idx + 4)
            let blockText = lines[start..<end].joined(separator: "\n")
            return Block(
                promptIdx: idx,
                start: start,
                end: end,
                normalized: normalizeForCompare(blockText)
            )
        }

        // 以最後一個 block 為基準
        let base = blocks.last!
        var removeRanges: [(start: Int, end: Int)] = []

        for block in blocks.dropLast() {
            let ratio = lcsMinRatio(block.normalized, base.normalized)
            if ratio >= 0.5 {
                removeRanges.append((block.start, block.end))
            }
        }

        guard !removeRanges.isEmpty else { return text }

        // 標記要移除的行
        var removeLines = Set<Int>()
        for range in removeRanges {
            for i in range.start..<range.end {
                removeLines.insert(i)
            }
        }

        let result = lines.enumerated()
            .filter { !removeLines.contains($0.offset) }
            .map { $0.element }
        return result.joined(separator: "\n")
    }

    /// 只保留中英文字母和 /():，去除所有符號、數字、空格
    private static func normalizeForCompare(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            if ch.isLetter {
                result.append(ch)
            } else if "/():".contains(ch) {
                result.append(ch)
            }
        }
        return result
    }

    /// 雙向 LCS 相似度（取最小值）
    ///
    /// 防止短字串在長文本中碰巧匹配到高比例的常見字元。
    private static func lcsMinRatio(_ s1: String, _ s2: String) -> Double {
        guard !s1.isEmpty, !s2.isEmpty else { return 0 }

        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        // LCS（滾動陣列）
        var prev = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            var curr = [Int](repeating: 0, count: n + 1)
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            prev = curr
        }

        let lcsLen = prev[n]
        let ratioA = Double(lcsLen) / Double(m)
        let ratioB = Double(lcsLen) / Double(n)
        return min(ratioA, ratioB)
    }
}
