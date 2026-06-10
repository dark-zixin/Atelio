---
name: atelio
description: 透過 Atelio 操作多個 AI CLI worker（任意 AI CLI，如 Claude Code / Codex / Gemini）— 開 session、派任務、判讀完成狀態、處理 approval、並行調度。當你要當 PM 協調多個 AI CLI 平行做事、或把任務分派給其他 AI worker 時使用。
argument-hint: "[任務描述，如：開 codex 在 /repo 做事]"
---
<!-- version: 0.1.0 -->

# Atelio — 多 AI CLI worker 操作手冊

你（orchestrator）透過 `atelio` CLI 操作 Atelio.app 管理的多個終端 session。每個 session 裡跑一個 AI CLI（或任何指令），你像 PM 一樣派任務、看結果、協調它們。

## 前置

1. **Atelio.app 必須在跑**（它是 IPC server）。先測連線：
   ```
   ~/.atelio/bin/atelio list
   ```
   回 `無法連線到 Atelio App` → app 沒開，請使用者開啟 Atelio.app 後再操作。
2. **怎麼呼叫**：CLI 在固定路徑 `~/.atelio/bin/atelio`（穩定契約路徑，不依賴 PATH 設定）。本手冊範例一律用此絕對路徑直接呼叫；**不要假設裸 `atelio` 在 PATH**——多數環境不在，會 `command not found`。

## 心智模型（先讀，再操作）

- **worker 是 agent，不是聊天框**。session 裡的 AI CLI 有完整檔案系統存取（讀寫檔、git、搜尋）。要給它檔案就**給路徑**（`請看 /path/to/x.md`），它自己會讀；**不要**把大段內容塞進 dispatch 文字。
- **你是唯一的 orchestrator（PM）**。Atelio 只負責管終端、收送文字、偵測狀態，**不替你做路由或決策**。
- **owner 綁定**：你 `open` 的 session 由你擁有。`dispatch`/`wait`/`close`/`send-keys` 只能對自己擁有的 session 操作；別人的 session 你只能 `screen`（唯讀）。owner（你這個 process）結束後 session 鎖定。
- **一個 session 同時只有一個 in-flight 操作**。對正在工作的 session 再 `dispatch` 會被擋（回 `turn_in_progress`），要先收割回 idle。
- **dispatch ≠ send-keys**：
  - `dispatch` = 送一則 user message 給 AI（自動包裝 + 提交），用於「給 AI 一個任務」。
  - `send-keys` = 送 raw 按鍵到 TUI（不提交、不包裝），用於「操作 AI CLI 的介面元件」，例如 approval 選單。兩者不可混用（見 approval 工作流）。

## 指令參考

### open — 開 session
```
~/.atelio/bin/atelio open <name> --cmd "<啟動指令>" --dir <工作目錄> --purpose "<用途>"
```
- `name` 必填、唯一（重複會被拒）。`--cmd` 預設 `/bin/zsh`、`--dir` 預設 `/tmp`、`--purpose` 預設空（供 list / 標題列顯示，多 worker 時建議填以便辨認）。
- 例：`~/.atelio/bin/atelio open reviewer --cmd codex --dir /repo --purpose "審查 PR"`
- 開 AI CLI 時把 CLI 當 cmd（`--cmd codex` / `--cmd claude` / `--cmd gemini`）。也可先開 shell 再在裡面手動啟動 AI CLI——Atelio 會在 dispatch 當下動態偵測 foreground 是不是 AI CLI。

### dispatch — 派任務並等完成
```
~/.atelio/bin/atelio dispatch <name> "<任務文字>" --timeout <秒>
```
- `--timeout` 預設 60；根據任務估算，寧可設大，timeout 到了仍可用 `wait` 繼續等。送出後**阻塞**直到完成或 timeout，回傳去噪後的本輪輸出。
- 回傳的 `result` 決定下一步，見「result 判讀」。

### wait — 等一個進行中的 turn 完成
```
~/.atelio/bin/atelio wait <name> --timeout <秒>
```
- session 已 idle → 立刻回當前畫面。仍在工作 → 等到完成或 timeout。
- 用在 dispatch 回 `turn_in_progress` / `deadline_reached` 後想繼續等。

### screen — 讀當前完整畫面
```
~/.atelio/bin/atelio screen <name>
```
- 回傳當前整頁畫面（含 scrollback，去噪後）。**不受 owner 限制**——別人的 session 也能看。
- 用於 dispatch/wait 回傳不足以判斷時（如 `turn_in_progress` 不帶 output）、回傳內容看不出狀況、或要查當前進度。

### status / list — 查狀態
```
~/.atelio/bin/atelio status <name>      # 單一 session 詳情
~/.atelio/bin/atelio list               # 列出所有 session
```

### send-keys — 送 raw 按鍵到 TUI
```
~/.atelio/bin/atelio send-keys <name> <key>
```
- key（大小寫不敏感）：`enter`、`esc`、`tab`、`space`、`bspace`（亦可寫 `return`/`escape`/`backspace`）、`up`/`down`/`left`/`right`、`c-<字母>`（Ctrl，如 `c-c`）、或任意**單字元**（如 `y`/`1`）。
- 不包 bracketed paste、不補 Enter。**不帶 output**（回傳只有操作確認），如需確認畫面結果用 `screen`。主要用於 approval 選單（見 approval 工作流）。

### close — 關 session
```
~/.atelio/bin/atelio close <name>
~/.atelio/bin/atelio close <name> --confirm <key>
```
- session 作業中時第一次 close 會要求二次確認、回傳裡帶確認 key；用 `--confirm <key>` 再 close 一次。
- 關閉後 name 釋放，可同名再開。

## result 判讀（dispatch / wait 回傳）

| result | 意義 | 你該做 |
|--------|------|--------|
| `hook_turn_ended` | AI CLI 透過 hook 確認完成 | 直接用 output，這是最終結果 |
| `quiet_window_met` | 畫面穩定（啟發式，**不等於任務完成**） | 看 output 判斷是否真的好了；沒好就 `wait` 或 `screen` |
| `turn_in_progress` | timeout 時 session 有 hook 記錄且 turn 仍未結束（不帶 output） | `wait` 繼續等，或 `screen` 看進度 |
| `deadline_reached` | timeout 時 session 無 hook 記錄，狀態不確定 | 看 output 判斷是否卡住；視情況再 `wait` |
| `process_exited` | session 裡的程式結束了 | 先 `close` 釋放名稱，需要的話再重新 `open` |
| `session_closed` | session 被關了 | 不再重試，重新 `open` |
| `owner_mismatch` | 你不是 owner | 只能 `screen` |
| `session_not_found` | session 不存在 | 確認名稱或 `open` |
| `invalid_request` | 參數錯 | 修正參數 |
| `internal_error` | server 內部錯 | 用 `screen`/`status` 查狀態再重試 |

## 工作流：基本回合

```
~/.atelio/bin/atelio open worker --cmd codex --dir /repo --purpose "做 X"
~/.atelio/bin/atelio dispatch worker "請做 X，完成後說明改了什麼" --timeout 120
# 看 result：
#   hook_turn_ended → 直接用 output
#   quiet_window_met → 看 output 判斷是否真完成；沒完成就 wait
#   turn_in_progress / deadline_reached → ~/.atelio/bin/atelio wait worker --timeout 120
~/.atelio/bin/atelio close worker
```

## 工作流：處理 approval

AI CLI 遇到需授權的操作（執行指令、寫檔等）會跳 approval 選單。**此時用 `send-keys`，不要用 `dispatch`**——dispatch 會把文字當 paste 補 Enter，誤觸選項。

`dispatch`/`wait` 回傳的 output **已含當前畫面**，直接從中判斷選項，不需額外 `screen`：

```
# dispatch 回傳的 output 顯示 approval 選單後，按畫面上的選項送鍵：
~/.atelio/bin/atelio send-keys worker 2     # 選畫面上編號 2 的選項
~/.atelio/bin/atelio send-keys worker esc   # 取消
~/.atelio/bin/atelio wait worker --timeout 120   # 選了同意後，等 AI 繼續做事
```
**以畫面顯示為準**——常見是數字選單或 y/n 提示，`esc` 通常取消。

## 工作流：並行多 worker

`dispatch` 是阻塞的。要並行多個 worker，靠 **orchestrator 自身的背景/並發能力**同時發出多個 dispatch；`--timeout` 要設大（理由同 dispatch 說明），否則提早回 `turn_in_progress`。

以 Claude Code 為例（用背景執行發 dispatch，完成時自動喚醒收割）：
```
Bash("~/.atelio/bin/atelio dispatch w1 '任務A' --timeout 1800", run_in_background=true)
Bash("~/.atelio/bin/atelio dispatch w2 '任務B' --timeout 1800", run_in_background=true)
# 兩個 worker 此刻並行在跑，你可以去做別的事；各自完成時分別回來收割
```
若 orchestrator 沒有背景執行能力，只能用阻塞 dispatch 依序跑。

## 配置：擴充 AI CLI 白名單

Atelio 靠白名單判斷 foreground 是否為 AI CLI，決定是否切片本輪輸出。內建：`codex` / `claude` / `gemini` / `aider`。

若不在清單裡（dispatch 回傳夾帶大量歷史），在 `~/.atelio/config.json` 的 `additional_ai_clis` 加上指令名即可（只能新增，不可覆蓋內建）。

## 提升完成偵測：安裝 hook（選用，AI CLI 限定）

完成偵測有兩種：hook 通知（精確，回 `hook_turn_ended`）和畫面穩定啟發式（回 `quiet_window_met`，不保證準確）。**此流程只對 AI CLI worker 有意義**——普通 shell 工具不適用。

**觸發時機**：dispatch/wait 回 `quiet_window_met` 時，進以下流程。

**流程**：
1. 讀 `~/.atelio/config.json` 的 `hook_skip`，查這個 CLI（`--cmd` 指定的指令名）有無 entry：
   - 有 entry，值為 `"never"` → 永久略過
   - 有 entry，值為日期且**未到期** → 略過
   - 有 entry，值為日期且**已過期** → 重查（步驟 2）
   - 無 entry → 步驟 2
2. **web search** 查該 CLI 當前的 hook 文件（能力與格式都可能改版，不憑記憶）：
   - **無 hook 機制** → 合併寫入 `hook_skip`：`"<cli>": "<今天 + 30 天>"`
   - **有 hook 機制** → 步驟 3
3. 即時查本機該 CLI 的 hook config，確認是否已掛 Atelio hook：
   - 已掛 → **驗證** hook 腳本路徑與觸發事件是否符合 Atelio 契約（`notify.sh turn_start/turn_end`）；符合 → 不動；不符合（改版或路徑變動）→ 步驟 4
   - 未掛 → 步驟 4
4. 問使用者要不要裝或更新（會改動該 CLI 全域設定，需同意）：
   - 同意 → 依步驟 2 查到的文件安裝（見下方契約）；安裝完成後刪除 `hook_skip` 裡此 CLI 的 entry（如果有）
   - 拒絕 → 同時問「要多久後再提醒？」：
     - 指定天數 → 合併寫入 `hook_skip`：`"<cli>": "<今天 + N 天>"`
     - 永不再問 → 合併寫入 `hook_skip`：`"<cli>": "never"`

**Atelio hook 契約**：CLI 回合開始執行 `~/.atelio/notify.sh turn_start`、結束執行 `notify.sh turn_end`；對應哪個 hook 事件依步驟 2 查到的文件決定。`notify.sh` 由 Atelio 預裝，非 Atelio session 時靜默略過；對該 CLI 全域一次。

**config.json 格式（hook_skip 欄位範例）**：
```json
{
  "hook_skip": {
    "codex": "2026-07-04"
  }
}
```
寫入時**合併**現有 config，不覆蓋整份。
