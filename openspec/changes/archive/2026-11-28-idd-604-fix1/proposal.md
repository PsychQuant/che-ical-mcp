## Problem

#604 第 1 輪驗證發現三個阻擋項：`delete_events_batch` 遇到同名日曆時建議傳一個它不接受的 `calendar_id`；規格說 `list_calendars` 的一列可以同時是兩種類型，程式做不到；規格說沒給來源的跨帳號同名也給候選 `id`，程式沿用舊訊息。另外帶 `spec-example` 標記的測試沒有走到做決定的程式。

## Root Cause

`listEvents` 把 `offersID: true` 寫死，而它也是批次刪除列事件用的讀取。規格的兩處描述寫得比實作寬。outcome 到錯誤的轉換寫在 actor 裡，不能用假資料測。

## Proposed Solution

讀取函式把 `offersID` 改成參數、預設 `false`，只有三個 range read 傳 `true`。把查找與拒絕的轉換抽成純函式，輸入是依實體類型取候選的 closure。規格收窄到實作的行為：`entity_types` 是這一列讀自哪個清單；沒給來源的跨帳號同名是唯一例外，沿用舊拒絕。

## Non-Goals

提醒事項工具、`delete_events_batch`、複製與搬移目標的 `calendar_id`，以及 calendar-routing 契約的 `id` 寫法（另開 issue）。

## Success Criteria

`delete_events_batch` 的拒絕建議改名；每個 Example 的測試走到做決定的函式；`swift test` 全部通過。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `calendar-resolution`: 收窄跨帳號與 `entity_types` 的描述，寫明哪些查找建議 `calendar_id`。

## Impact

- Affected specs: `calendar-resolution`
- Affected code: `Sources/CheICalMCP/EventKit/CalendarResolution.swift`、`Sources/CheICalMCP/EventKit/EventKitManager.swift`、`Sources/CheICalMCP/EventRangeReadSource.swift`、`Sources/CheICalMCP/Server.swift`、`Tests/CheICalMCPTests`、文件
