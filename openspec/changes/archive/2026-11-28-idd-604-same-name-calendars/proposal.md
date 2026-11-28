## Problem

同一個帳號底下有兩個標題相同的日曆時，`calendar_name` ＋ `calendar_source` 區分不了它們（#604）：

- 讀取端（`list_events`、`list_events_quick`、`search_events`、`check_conflicts`、`delete_events_batch` 的清單、提醒事項的讀取）給了 `calendar_source` 之後，`findCalendars` 回傳所有同標題同來源的日曆，**靜默合併**，沒有錯誤也沒有警告。
- 寫入端（`create_event`、`update_event` 搬移、複製與搬移的目標、提醒事項的寫入）的 `findCalendar` 會拒絕，但訊息寫「請指定 calendar_source」，而呼叫端早已指定，這個拒絕沒有辦法照著做。
- 沒有任何工具接受日曆 `id`，雖然 `list_calendars` 每一列都有 `id`。
- `list_calendars` 不帶 `type` 時把事件日曆與提醒事項清單接在一起回傳，每一列沒有說明它是哪一種。同帳號下一個事件日曆與一個同名的提醒事項清單，會看起來像兩個同名日曆，卻沒有任何欄位能分辨。

## Root Cause

日曆的辨識只靠標題與來源標題（`CalendarNameMatch.matching`），而「符合的不只一個」的處理在讀取端與寫入端不一致：讀取端在有 `calendar_source` 時放行，寫入端無論如何都拒絕並給出不實用的建議。

## Proposed Solution

- 在 `CalendarNameMatch` 旁新增一個純的泛型解析器：輸入標題、來源與選填的 `id`，回答「剛好一個」「沒有」或「不只一個（附候選的 `id`）」。`id` 優先於標題與來源，且必須屬於要求的實體類型；`id` 與同時給的標題或來源不一致時拒絕，不靜默忽略其中一個。
- `findCalendar` 與 `findCalendars` 都用它：標題加來源仍符合不只一個時，讀取端與寫入端一律拒絕；拒絕訊息只放候選的 `id`（通過格式檢查才放），不放標題或來源標題；工具有 `calendar_id` 時建議使用它，沒有時建議在日曆 App 裡改名。
- 事件工具 `list_events`、`list_events_quick`、`search_events`、`check_conflicts`、`create_event`、`create_events_batch` 的每一列、`update_event` 新增 `calendar_id`。
- `list_calendars` 的每一列新增 `entity_types`，標明它是事件日曆、提醒事項清單，或兩者。
- 新增的測試只用純函式與替身，不讀寫真實的 EventKit store。

## Non-Goals

- 提醒事項工具的 `calendar_id`、`delete_events_batch`、`copy_event` 與 `move_events_batch` 的 `target_calendar_id`：這幾個工具在這次變更後遇到同名日曆時會拒絕（不再靜默選擇或合併），但還不能用 `id` 指定，另開 issue 追蹤。
- `calendar-routing` 契約（plugin 的規則檔）加入 `id` 寫法：另開 issue。
- 不嘗試判斷「哪一個才是使用者要的」：同名時一律由呼叫端指定。

## Success Criteria

- 兩個同標題同來源同類型的日曆：上述事件工具不帶 `calendar_id` 時，讀取與寫入都回拒絕，訊息列出候選 `id`；帶 `calendar_id` 時只作用在那一個。
- 只有一個日曆符合時，所有工具的行為與回應不變。
- `list_calendars` 每一列帶 `entity_types`。

## Capabilities

### New Capabilities

- `calendar-resolution`: 工具如何由標題、來源與日曆 `id` 找到一個日曆，以及找不到、不只一個、兩種條件互相矛盾時的拒絕。

### Modified Capabilities

(none)

## Impact

- Affected specs: 新增 `calendar-resolution`
- Affected code: `Sources/CheICalMCP/EventKit/EventKitManager.swift`、`Sources/CheICalMCP/EventKit/DuplicateCalendars.swift`（或新檔案放解析器）、`Sources/CheICalMCP/Server.swift`、`Sources/CheICalMCP/EventRangeReadSource.swift`、`Sources/CheICalMCP/EventWriteSource.swift`、`Sources/CheICalMCP/EventReadValue.swift`、`Tests/CheICalMCPTests`
