## Why

重複事件裡被單獨修改過的場次有自己的識別碼（iCloud，以及經 EventKit 讀到的 Google：系列識別碼加上 `/RID=` 與一個數字）。`update_event`、`delete_event`、`move_events_batch` 的場次查找只比對系列識別碼本身，所以用系列識別碼加那個場次的日期會得到「找不到」，而行事曆上那一天明明有場次（#532）。同一個落空讓 `create_event` 把仍有被修改場次的排除日讀成已排除，回 `skipped`（#534）。找不到的訊息還把要求的日期印成 UTC 時刻（#535）。

## What Changes

- `update_event`、`delete_event`（span `this` 或 `future` 帶 `occurrence_date`）與 `move_events_batch`（span `this` 帶日期）的查找落空時，再找這個系列裡屬於那一天、被單獨修改過的場次：在那一天開始的，或原本的時段在那一天、現在改到別天開始的。找到一個以上就拒絕，訊息給出每一個的識別碼，什麼都不寫。查找本身（`findOccurrence`）不變，原本解析得到的呼叫照舊。
- 拒絕訊息依工具與 span 不同：span `this` 說把識別碼當成 `event_id`、不帶 `occurrence_date`；`update_event` 的 span `future` 給出識別碼，另一條路用既有 #416 拒絕訊息的同一句（同一個常數）；`delete_event` 的 span `future` 說明那個刪除從哪一天開始、不能 undo；`move_events_batch` 的列說明 `event_ids` 與 `occurrence_dates` 怎麼填。
- 識別碼只有在全部由允許的字元組成、長度不超過 200 時才寫進訊息；否則訊息改指向 `list_events`。
- 找不到、或系列列不出來時，答案仍是找不到，訊息改用讀取日期的時區印出 `yyyy-MM-dd`（#535）。
- `create_event` 與 `create_events_batch`：排除日上有既有系列被單獨修改過的場次開始時，算作仍然存在，回既有的衝突錯誤，不回 `skipped`（#534）。對原本在這個形狀回 `skipped` 的重試是 **BREAKING（行為）**。
- 工具說明（`Server.swift` 與 `mcpb/manifest.json`）、兩份 README、CHANGELOG、release gate 規則檔同步說明。

## Non-Goals (optional)

- 經系列識別碼找到被修改的場次並寫入（#532 Diagnosis 的選項 A、C）。這裡只拒絕並指出識別碼。
- 既有 #416 拒絕訊息的文字：只讀，不改。
- `deleteEventsBatch`、`applyExclusions`、`copy_event`、undo（被拒絕的呼叫不留紀錄）。
- 被移離排除日的場次不讓 `create_event` 衝突，仍回 `skipped`，寫成已知限制（計畫審查時決定）。
- Google 與 Exchange 的量測。

## Capabilities

### New Capabilities

- `edited-occurrence-addressing`: 系列識別碼加日期指到被單獨修改過的場次時，`update_event`、`delete_event`、`move_events_batch` 的答案，以及找不到時訊息印出的日期。

### Modified Capabilities

- `recurrence-excluded-dates`: requirement「Idempotent retry and conflict detection」把在排除日開始、被單獨修改過的場次算作仍然存在。

## Impact

- Affected specs: `edited-occurrence-addressing`（新增）、`recurrence-excluded-dates`（修改）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`（新增）
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`
  - `Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift`
  - `Sources/CheICalMCP/EventKit/DetachedOccurrenceSpan.swift`
  - `Sources/CheICalMCP/Server.swift`
  - `mcpb/manifest.json`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`（新增）
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressHandlerTests.swift`（新增）
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift`（新增）
  - `Tests/CheICalMCPTests/ManifestParityTests.swift`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`
  - `.claude/rules/mcp-binary-version-testing.md`
