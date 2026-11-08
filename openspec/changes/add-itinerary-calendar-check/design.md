## Context

#341 的 Diagnosis 原本以 skill 名稱的封閉清單為鍵，透過 `Skill` 工具上的 hook 觸發。維護者 2026-10-28 的決定換掉了這個做法：別人安裝的 plugin 不能寫死其他 plugin 的 skill。改為看旅程資料夾，也就是最近的專案層 `.claude/.ical/config.yaml` 所在的資料夾（#337 已找得到），預設為開。

## Decisions

### 用 Stop hook 的 additionalContext，不用 block

Claude Code hooks 參考文件（`hooks.md` 的 Stop decision control 一節，2026-11-09 讀）寫明：`Stop` 的 `hookSpecificOutput.additionalContext` 是非錯誤的回饋，對話會繼續讓 Claude 處理；它受與 `decision: "block"` 相同的迴圈保護（`stop_hook_active` 輸入與連續 8 次的上限）。hook 另外自己守住：
- `stop_hook_active` 為 true 時不輸出；
- 輸出前先寫 `.reminded` 紀錄，所以每個 session 只提醒一次；
- 寫不了這個紀錄時就不輸出，免得每個回合都提醒。

### Session 開始時間放在 `${CLAUDE_PLUGIN_DATA}`

同一份參考文件寫 `CLAUDE_PLUGIN_DATA` 是 plugin 的持久資料目錄。hook 在那裡寫 `itinerary-sessions/<session_id>.start`，session id 只接受 `[A-Za-z0-9_-]`。開始時間只記一次：resume、`/clear`、compaction 都保留第一次的紀錄。開始時刪掉超過 30 天的紀錄。這個變數沒設時 hook 什麼都不做。

### 走訪資料夾有上限

只讀檔名與修改時間，不讀內容。略過 `.git/`、`.claude/` 與 symlink。2 秒或 50 000 個項目後停下，並說明清單提早停止。列出 20 個檔案，其餘只算數量。`hooks.json` 給這個指令 10 秒的 timeout。

### 設定鍵不用 YAML 函式庫讀

hook 只讀兩個頂層鍵：
- `itinerary_check`：`off` 或 `false` 關閉提醒，引號有無、大小寫都可以。
- `itinerary_ignore`：行內清單或區塊清單。

macOS 的 python3 預設沒有 YAML 模組，所以用逐行解析讀這兩個鍵；檔案其他內容 hook 不看。

### 檢查本身不寫入

`itinerary-check` 的 `allowed-tools` 只列讀取工具。變更走擁有那個事件的路徑：會議模組的部分更正、住宿模組，或在使用者同意後用 `update_event`／`create_event`；所以每次寫入也會再問一次權限。

## Risks / Trade-offs

- 提醒可能是白提醒：檔案改了不代表旅程事實改了。skill 會一行回答。
- 既有的專案層設定檔使用者升級後會開始收到提醒。CHANGELOG 與 README 寫明，`itinerary_check: off` 可關閉。
- 在旅程資料夾裡，每個 session 多花一個模型回合。
