## Why

使用者追蹤好幾種「不用就作廢」的額度：每個訂閱帳號的週用量上限、每個帳號的月度 API 額度。每一筆都是專用提醒事項清單裡的提醒，訂在重置前的最後時刻，用完就打勾；沒打勾就變逾期，表示那一期沒用完。這些提醒目前都是手工以 `create_reminder` / `update_reminder` 建的，格式只存在使用者的筆記裡，時區換算與提前量也靠手算（PsychQuant/che-ical-mcp#327）。

## What Changes

- 新增 plugin skill `quota`（`/che-ical-mcp:quota`），五個操作：`declare`、`update`、`retire`、`list`、`sync`。
- 宣告存在一份全域檔 `~/.claude/.ical/quotas.yaml`（不從工作目錄往上找；額度屬於帳號，不屬於資料夾）；提醒由它產生，檔案只放標籤，不放憑證。`find-ical-config.sh --quotas` 對它做與 `config.yaml` 相同的擁有者與權限檢查（0 可信、1 不存在、3 存在但不可信）。
- 新 helper `plugin/bin/quota-dates.sh`（bash 與系統 `date`）：算每一期的鍵（重置日）、重置、到期（重置減提前量）與提醒偏移。
- v1 只有 per-period：每一期一則一次性提醒，notes 帶 `Period: <key>`，`sync` 補到接下來 90 天。沒有重複提醒（verify 第 5 輪收窄：rule mode 的每一期都要從一則滾動的提醒推回去，五輪的發現幾乎都出在這裡）。
- 規劃由 `plugin/bin/quota-plan.sh` 算：以期別鍵比對；紀錄要寫下來（`Record: <key>`），不從日期推。
- 到期一律訂在真正的截止時刻；提早通知用相對鬧鐘（`notify_at`：到期前最近的當地 HH:MM），另加一個到期時的 `0` 分鐘鬧鐘。純日期的額度不設鬧鐘。
- 標題 `Use up <name> (<account>, <when>)`；notes 用固定標籤行，最後一行 `quota-module: <id>`，以下是使用者的文字、更新時保留。
- 只改說明欄位的更新就地改寫；改了日期的更新是取代：保留紀錄（寫下 `Record:`）、建立新排程、刪除其餘未完成的提醒，問一次、同意才做。退役只刪未完成的那幾則，且要在這次執行裡針對該額度問過、得到同意；已完成的紀錄與紀錄都不動。
- Known limits：sync 每 90 天至少要跑一次，否則提醒會用完；改排程會取代未完成的提醒。
- 不改 Swift。依賴 #333（提醒的相對鬧鐘），已在 `main` 上、尚未發布，所以 skill 要等下一個 binary release；`plugin.json` 版號不動（與 binary 版號綁定）。

## Non-Goals

- 不加 MCP tool（Claude Desktop 用不到這個 skill）；有需要再另開 issue。
- 不建行事曆事件（決策紀錄第 3 列）。
- 不自動依提供者的帳單頁核對重置日；`check_note` 與 `verify_next_period` 只提醒使用者自己查。
- 不處理 app store 內購的續訂規則；clamp 規則是預設，不是每家提供者的事實。

## Impact

- 新增：`plugin/skills/quota/SKILL.md`、`plugin/bin/quota-dates.sh`、`plugin/bin/tests/quota-dates.test.sh`、`plugin/bin/quota-plan.sh`、`plugin/bin/tests/quota-plan.test.sh`、`openspec/changes/add-quota-reminders/`、`Tests/CheICalMCPTests/QuotaSkillDocsTests.swift`。
- 修改：`plugin/bin/find-ical-config.sh`（`--quotas`）與其測試、`.github/workflows/test.yml`（跑三個 shell 測試）、`plugin/README.md`、`plugin/CLAUDE.md`、`plugin/CHANGELOG.md`。
