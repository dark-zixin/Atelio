[English](README.md) | [繁體中文](README.zh-TW.md)

# Atelio

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-brightgreen)

把多個 AI CLI（Claude Code、Codex、Gemini …）當成 worker，跑在 macOS 的終端機視窗裡。你的主 AI 只用一個 `atelio` 指令列工具就能操作它們，像 PM 派任務那樣，同時調度多個 worker。

**[下載最新版本](https://github.com/dark-zixin/Atelio/releases/latest)**

<p align="center">
  <img src="assets/atelio-demo.gif" alt="Atelio 操作示範" width="900">
</p>

## 解決什麼問題

你想同時讓好幾個 AI CLI 各做各的：一個審程式碼、一個寫測試、一個查資料。問題是它們各自關在獨立的終端機裡：

- **沒辦法統一控制** — 只能手動切視窗、盯著看哪個跑完了、再一個個複製貼上
- **沒有「turn 完成」的訊號** — tmux 這類終端多工器頂多幫你把視窗排好，但它不知道 AI CLI 什麼時候*跑完一個 turn*，你也就無法用程式自動收結果
- **缺一個 orchestrator 來帶多個 worker** — 想讓單一主 AI 去派任務、盯進度、協調其他 AI worker，沒有現成又順手的管道

## 運作方式

1. 每個 AI CLI 都當成一個 **worker**，由 Atelio 跑在獨立的終端 session 裡
2. 你的主 AI 用 `atelio` 指令操作它們：`open` / `dispatch` / `wait` / `screen`
3. 每個 worker 一**跑完 turn**，Atelio 就會偵測到（靠 hook，或畫面穩定的啟發式判斷），把這一輪的輸出去噪後單獨回傳給你

主 AI 扮演 orchestrator（編排者，也就是 PM）；Atelio 只管終端、傳遞文字、回報狀態，不替你做路由判斷、也不替你做決定。

## 功能

- **多 session 終端容器** — 自動排版，一個就全螢幕、兩個就左右並排、最多到 2×2 grid
- **用 CLI 編排** — `open` / `dispatch` / `wait` / `screen` / `send-keys` / `reset` / `close`
- **turn 完成偵測** — 優先用 hook 精準通知，收不到就退而用畫面穩定的啟發式判斷
- **owner 綁定** — 你開的 session 只有你能操作，別人只能看不能動
- **approval 處理** — 用 `send-keys` 操作 worker 的 TUI 選單，回應授權提示
- **輸出去噪、按 turn 切片** — 只把這一輪乾淨的輸出回傳給你
- **接任何 AI CLI** — 內建 `claude` / `codex` / `gemini` / `aider` 白名單，要加別的改 config 就行
- **不需要任何特殊權限** — 不碰輔助使用、不碰螢幕錄製；只走本機 Unix socket，全程不連外

## 系統需求

- macOS 26.4 以上
- 想當 worker 用的 AI CLI 要自己先裝好（例如 `claude` / `codex` / `gemini`）

## 安裝

1. 到 [Releases](../../releases) 下載最新的 `Atelio.dmg`
2. 打開 DMG，把 **Atelio** 拖進**應用程式**資料夾
3. 從 Launchpad 或應用程式資料夾啟動

第一次啟動時，Atelio 會自動把 `~/.atelio/` 準備好（設定、log、socket、CLI symlink、操作手冊鏡像都在裡面），你不用手動設定。

> 如果 macOS 擋下這個 app，在 Atelio.app 上按右鍵選「打開」一次就過了。（公證版可以直接開。）

## 首次設定：讓你的 AI 讀懂 Atelio

Atelio 內附一份操作手冊（也就是一個 skill），啟動後會鏡像到 `~/.atelio/skills/atelio/`。剩下要做的，就是把它接進主 AI 會去掃的 skill 目錄：

- **最省事的做法** — 打開 Atelio 的「說明」視窗，把那段 prompt 複製給你的 AI，它會照自己的環境把 skill 接好
- **手動接** — 把 `~/.atelio/skills/atelio` 用 symlink 連進你的 AI skill 目錄。建議用 symlink，這樣 App 一更新就會自動同步。常見位置：Claude Code 在 `~/.claude/skills/`，Codex / Gemini 在 `~/.agents/skills/`

接好之後，直接用一句話交代主 AI 就行，例如：「在 /repo 開一個 codex worker，去做 X」。

## 使用方式

平常操作都交給主 AI 透過 skill 去做，你只要讓 Atelio 一直開著就好。底層的 CLI 固定放在 `~/.atelio/bin/atelio`：

| 指令 | 作用 |
|---|---|
| `atelio open <name> --cmd <cli> --dir <路徑>` | 開一個 worker session |
| `atelio dispatch <name> "<任務>"` | 派一個任務，並等它跑完 |
| `atelio wait <name>` | 等正在進行的 turn 跑完 |
| `atelio screen <name>` | 看當下的畫面（唯讀，誰的 session 都能看） |
| `atelio list` / `atelio status <name>` | 查 session 狀態 |
| `atelio send-keys <name> <key>` | 送一個按鍵給 TUI（用來操作 approval 選單） |
| `atelio reset <name>` | 強制結束卡住的 turn |
| `atelio close <name>` | 關掉 session |

完整指令、result 狀態怎麼判讀、以及各種工作流，都寫在 [`skill/atelio/SKILL.md`](skill/atelio/SKILL.md)。App 裡的「說明」視窗也有一份速查表和快捷鍵。

### 快捷鍵

`⌘=` 放大文字 · `⌘-` 縮小 · `⌘0` 重設 · `⌘W` 關視窗（App 繼續跑） · `⌘Q` 結束 Atelio

## 信任模型

Atelio 是一個本機桌面 App，用你平常的使用者身分執行：

- 它 spawn 出來的 worker，就是**你自己裝**的那些 AI CLI，跑在你自己的 shell 環境裡
- IPC 走本機 Unix domain socket（`~/.atelio/atelio.sock`），**它自己不會開任何對外連線**
- 所有資料都集中在 `~/.atelio/` 底下
- **完全用不到**輔助使用、螢幕錄製、完整磁碟取用這類特殊系統權限

## 解除安裝

1. 刪掉 `/Applications/Atelio.app` 和 `~/.atelio/`
2. 把你 AI skill 目錄裡的 `atelio` symlink 移掉（例如 `~/.claude/skills/atelio`）
3. 如果之前裝過完成偵測用的 hook，到各 AI CLI 的設定裡，把指向 `~/.atelio/notify.sh` 的那幾項刪掉

## 從原始碼建置

1. Clone 這個 repository
2. 用 Xcode 打開 `Atelio/Atelio.xcodeproj`
3. 選 **Atelio** scheme 跑起來（需要 macOS 26.4+ 的 SDK）

SwiftTerm 這個依賴交給 Swift Package Manager 自動解析；隨 bundle 一起的 AtelioCLI 和 AtelioShared.framework，build 過程會自動處理好。

## 貢獻

歡迎開 Issue、發 Pull Request。回報 bug 的時候，麻煩附上你的 macOS 版本，還有你當成 worker 在跑的是哪個 AI CLI。

## 授權

[MIT License](LICENSE) © 2026 dark-zixin
