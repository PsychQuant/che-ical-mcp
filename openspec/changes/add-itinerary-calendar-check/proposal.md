## Why

旅程相關的工作把事實記在那份工作所在的地方：收據在信件歸檔、修訂的議程在會議資料夾。那份工作沒有一步知道行事曆是第二個要更新的地方，所以行事曆會安靜地落後：費用已付，事件還寫「某日前繳費」；議程改了，場次還在舊的時段（PsychQuant/che-ical-mcp#341）。plugin 無法列舉別的 plugin 的 skill，所以改看旅程資料夾；這個資料夾 plugin 已經找得到（#337）。

## What Changes

- `SessionStart` hook 記下 session 開始的時間；`Stop` hook 列出從那時起，最近的**專案層** `.claude/.ical/config.yaml` 所在資料夾裡改過的檔案（使用者層的 `~/.claude/.ical/config.yaml` 不算）。有檔案改過時，`Stop` hook 加一則 `additionalContext`，請 Claude 執行 `itinerary-check`，每個 session 至多一次。它不阻擋：一律 exit 0，其餘時候不輸出。
- 該設定檔的 `itinerary_check: off` 關閉提醒，`itinerary_ignore:` 列出要略過的 glob；`.git/` 與 `.claude/` 一律略過。
- 新 skill `itinerary-check`：從改過的檔案讀出旅程事實（報名、付款、議程、住宿、交通），依序找旅程的事件（模組標記、`state/archives.json`、名稱加日期範圍），逐項比對。全部相符時一行回答；有差異時把每一項列成一張表，使用者同意前不改任何東西。議程修訂走會議模組的部分更正，住宿走住宿模組。
- **升級影響**：預設為開（維護者 2026-10-28 決定），所以既有的專案層設定檔升級後會開始收到提醒。CHANGELOG 與 README 寫明，`itinerary_check: off` 可關閉。
- 不改 Swift、不發 binary release。

## Non-Goals

- 偵測旅程**事實**改了：hook 只看檔案時間，所以有些提醒是白提醒。
- 只存在資料夾外的事實（例如從沒歸檔的信）。
- 強制執行：提醒只是提示，不用會阻擋的 `Stop` hook。
- 審稿截止、教學與行政截止。

## Capabilities

### New Capabilities

- `itinerary-calendar-check`：旅程資料夾提醒與檢查 skill。

### Modified Capabilities

（無：會議模組、住宿模組、日曆路由與事件來源歸檔的既有 requirement 只被引用，不修改）

## Impact

- 影響的檔案：`plugin/hooks/hooks.json`、`plugin/hooks/itinerary-reminder.sh`、`plugin/hooks/itinerary_reminder.py`、`plugin/skills/itinerary-check/SKILL.md`、`plugin/rules/event-modules.md`（一行指引）、`plugin/CLAUDE.md`、`plugin/README.md`、`plugin/CHANGELOG.md`、`scripts/tests/itinerary-reminder-test.sh`、`.github/workflows/test.yml`。
