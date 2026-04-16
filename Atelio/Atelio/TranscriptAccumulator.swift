import Foundation

/// Transcript 累積器：管理 TUI（alt-screen）模式下被推掉的行的歷史記錄
class TranscriptAccumulator {

    // MARK: - 狀態

    private var transcript: [String] = []
    private let maxTranscriptLines = 3000

    /// 上一幀的所有行（用於 overlap 比對）
    private var prevFrameRows: [String]?

    /// 上一幀的終端尺寸（用於偵測 resize）
    private var prevFrameSize: (cols: Int, rows: Int)?

    /// 是否有 transcript 資料
    var hasTranscript: Bool { !transcript.isEmpty }

    // MARK: - 公開方法

    /// TurnCoordinator tick 呼叫：如果 TUI + 畫面變了，累積 transcript
    func accumulate(screen: String, terminalSize: (cols: Int, rows: Int)) {
        let currRows = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let currentSize = terminalSize

        guard let prev = prevFrameRows else {
            // 第一幀 → 記錄，不做其他事
            prevFrameRows = currRows
            prevFrameSize = currentSize
            return
        }

        // 偵測 resize
        if let prevSize = prevFrameSize,
           (prevSize.cols != currentSize.cols || prevSize.rows != currentSize.rows) {
            appendToTranscript(prev)
            appendGapMarker()
            prevFrameRows = currRows
            prevFrameSize = currentSize
            return
        }

        // Fast-path：比對前 3 行，如果相同 → 頂部沒變 → 跳過
        let prevTopLines = prev.prefix(3).map { normalizeLine($0) }
        let currTopLines = currRows.prefix(3).map { normalizeLine($0) }
        if prevTopLines == currTopLines {
            prevFrameRows = currRows
            prevFrameSize = currentSize
            return
        }

        // 頂部變了 → 做 suffix-prefix overlap
        let (departed, overlapFound) = findDepartedLines(prev: prev, curr: currRows)

        if !departed.isEmpty {
            let meaningful = departed.filter { !normalizeLine($0).isEmpty }
            if !meaningful.isEmpty {
                appendToTranscript(departed)
            }
            if !overlapFound {
                appendGapMarker()
            }
        }

        prevFrameRows = currRows
        prevFrameSize = currentSize
    }

    /// alt-screen 進入時呼叫
    func handleAltScreenEnter() {
        resetTranscript()
    }

    /// alt-screen 離開時呼叫
    func handleAltScreenExit() {
        resetTranscript()
    }

    /// 讀完整 output（有 transcript → 組合版 / 沒有 → nil，由呼叫方用 full buffer）
    func readTranscript(viewport: String) -> String? {
        guard hasTranscript else { return nil }

        let viewportLines = viewport.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let joined = overlapJoin(transcript: transcript, viewport: viewportLines)
        return joined.joined(separator: "\n")
    }

    // MARK: - 內部方法

    /// 清除所有累積的 transcript（新 turn 開始時呼叫）
    func reset() {
        transcript.removeAll()
        prevFrameRows = nil
        prevFrameSize = nil
    }

    private func resetTranscript() {
        reset()
    }

    /// 正規化行內容用於比對（null bytes 替換為空格，去除頭尾空白）
    private func normalizeLine(_ line: String) -> String {
        let cleaned = line.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" {
                return " "
            }
            return Character(scalar)
        }
        return String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把行存入 transcript（ring buffer，超過上限刪最舊的）
    private func appendToTranscript(_ lines: [String]) {
        transcript.append(contentsOf: lines)
        if transcript.count > maxTranscriptLines {
            let overflow = transcript.count - maxTranscriptLines
            transcript.removeFirst(overflow)
            if !transcript.isEmpty && !transcript[0].hasPrefix("[truncated") {
                transcript.insert("[truncated: 歷史紀錄超過 \(maxTranscriptLines) 行上限]", at: 0)
            }
        }
    }

    /// 插入 gap marker
    private func appendGapMarker() {
        if let last = transcript.last, last.contains("[snapshot gap]") {
            return
        }
        transcript.append("... [snapshot gap] ...")
    }

    /// suffix-prefix overlap：找 curr 的頂部在 prev 中的位置
    private func findDepartedLines(prev: [String], curr: [String]) -> (departed: [String], overlapFound: Bool) {
        for currAnchorIdx in 0..<min(curr.count, 5) {
            let currNorm = normalizeLine(curr[currAnchorIdx])
            if currNorm.isEmpty { continue }

            for prevIdx in 0..<prev.count {
                let prevNorm = normalizeLine(prev[prevIdx])
                if prevNorm != currNorm { continue }

                var matchCount = 0
                var nonEmptyMatchCount = 0
                var pi = prevIdx
                var ci = currAnchorIdx
                while pi < prev.count && ci < curr.count {
                    let p = normalizeLine(prev[pi])
                    let c = normalizeLine(curr[ci])
                    if p == c {
                        matchCount += 1
                        if !p.isEmpty { nonEmptyMatchCount += 1 }
                    } else {
                        break
                    }
                    pi += 1
                    ci += 1
                }

                if matchCount >= 5 && nonEmptyMatchCount >= 3 {
                    let departedEnd = max(0, prevIdx - currAnchorIdx)
                    let departed = Array(prev[0..<departedEnd])
                    return (departed, true)
                }
            }
        }

        return (prev, false)
    }

    /// transcript + viewport 的 overlap join（去重合併）
    private func overlapJoin(transcript: [String], viewport: [String]) -> [String] {
        guard !transcript.isEmpty, !viewport.isEmpty else {
            return transcript + viewport
        }

        for vAnchorIdx in 0..<min(viewport.count, 5) {
            let vLine = normalizeLine(viewport[vAnchorIdx])
            if vLine.isEmpty { continue }

            let searchStart = max(0, transcript.count - 100)
            for tIdx in searchStart..<transcript.count {
                let tLine = normalizeLine(transcript[tIdx])
                if tLine != vLine { continue }

                var matchCount = 0
                var nonEmptyMatchCount = 0
                var ti = tIdx
                var vi = vAnchorIdx
                while ti < transcript.count && vi < viewport.count {
                    let t = normalizeLine(transcript[ti])
                    let v = normalizeLine(viewport[vi])
                    if t == v {
                        matchCount += 1
                        if !t.isEmpty { nonEmptyMatchCount += 1 }
                    } else {
                        break
                    }
                    ti += 1
                    vi += 1
                }

                if matchCount >= 5 && nonEmptyMatchCount >= 3 {
                    let cutPoint = max(0, tIdx - vAnchorIdx)
                    return Array(transcript[0..<cutPoint]) + viewport
                }
            }
        }

        return transcript + viewport
    }
}
