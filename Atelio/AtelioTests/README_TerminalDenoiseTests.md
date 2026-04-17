# TerminalDenoiseTests 手動加入 target 的說明

## 背景

`TerminalDenoiseTests.swift` 是新增的單元測試檔案，驗證 `TerminalDenoise.clean(_:marker:)` 的
marker 切片行為（Turn Marker 切片功能）。

## 為什麼需要手動加入

`AtelioTests` target 是傳統的 xcodeproj target（非 file-system-synchronized），
測試檔案必須明確列在 `project.pbxproj` 的 `PBXSourcesBuildPhase` 中才會被編譯。
為了避免動 xcodeproj 造成 merge 衝突，本次改動只建立檔案而未修改 xcodeproj。

## 加入步驟

1. 在 Xcode 中開啟 `Atelio.xcodeproj`
2. 在 Project navigator 展開 `AtelioTests` group
3. 右鍵 → Add Files to "Atelio"... 選擇 `TerminalDenoiseTests.swift`
4. 確認：
   - Target Membership 勾選 `AtelioTests`
   - Copy items if needed 不勾選
5. 建置 AtelioTests scheme（如果沒有 shared scheme 需自行建立）

## 測試內容

驗證 `TerminalDenoise.clean(_:marker:)` 的 marker 參數行為：
- nil / 空字串 / 找不到 → 原文 pass through
- 找到 marker → 從 marker 那行之後回傳
- 多次出現 → 以第一次出現為準
- 在最後一行 → 回傳空字串
- 與其他 pipeline 步驟的協同作用

## 已驗證

- `xcodebuild -scheme Atelio build`：成功
- `xcodebuild -scheme Atelio build-for-testing`：成功

`xcodebuild -target AtelioTests` 會因既有的 SwiftTerm 跨架構 build 設定問題而失敗
（與本次改動無關，在未加改動前也會出現）。
