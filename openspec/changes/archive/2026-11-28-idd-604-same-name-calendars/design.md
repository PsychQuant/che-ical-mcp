## Context

`EventKitManager.findCalendar`（寫入端）與 `findCalendars`（讀取端）以 `CalendarNameMatch.matching` 比對標題與來源標題，之後各自處理「符合不只一個」：寫入端一律拒絕並建議「指定 calendar_source」，讀取端在已給 `calendar_source` 時回傳全部符合的日曆。兩者都沒有日曆 `id` 的路徑。`list_calendars` 不帶 `type` 時回傳事件日曆加提醒事項清單，列裡沒有實體類型。

## Goals / Non-Goals

**Goals:**

- 同標題同來源的日曆在讀取端與寫入端一律拒絕，並讓呼叫端能用 `calendar_id` 指定。
- `list_calendars` 讓兩種實體類型能分辨。
- 解析規則是一個可用假資料測試的純函式。

**Non-Goals:**

- 提醒事項工具、`delete_events_batch`、`copy_event`、`move_events_batch` 的 `calendar_id`（拒絕仍適用，訊息建議改名）。
- `calendar-routing` 契約的 `id` 寫法。

## Decisions

### 一個純的泛型解析器，管理器的兩個查找函式共用

解析器放在 `CalendarNameMatch` 旁，輸入全部候選、標題、來源、`id`，輸出 `found`、`notFound`、`idMismatch`、`ambiguousAccounts`（沒給來源、符合的跨不同來源）或 `ambiguousInAccount`（同一個來源裡不只一個）。管理器的 `findCalendar` 與 `findCalendars` 都呼叫它，讀取端與寫入端的差別只剩回傳一個或一個陣列。替代方案是在兩處各自加判斷：已經分歧一次（這個 bug），不再重複。

### `id` 優先，且與標題、來源不一致就拒絕

`calendar_id` 選中的日曆若不符合同時給的 `calendar_name` 或 `calendar_source`（用同一個標題與來源比對規則），拒絕，不靜默忽略其中一個。候選集合是要求的實體類型的日曆，所以另一種類型的 `id` 自然是找不到。替代方案是 `id` 蓋過其他兩個：呼叫端打錯名稱時得不到任何提示。

### 拒絕訊息只放候選的 `id`

沿用 #37 的規則：日曆標題與來源標題可以由遠端發布者設定，不放進訊息。`id` 只在每一個都只含英數字與連字號、長度不超過 64 時列出，否則不列。呼叫端取得標題與來源的路徑仍是 `list_calendars`。

### 新的拒絕訊息依工具有沒有 `calendar_id` 而不同

管理器的查找函式不知道呼叫它的是哪個工具，所以由呼叫端傳一個旗標 `offersID`；傳了 `calendar_id` 參數的工具傳 `true`。訊息在 `true` 時建議傳 `calendar_id`，否則建議在日曆或提醒事項 App 裡改名。

### 不改現有協定的簽名

讀取端的協定（`EventRangeReadSource`）有十二個測試檔裡的替身。新增的 `calendarID` 以新的協定要求加入，並在協定擴充裡給預設實作：`calendarID` 是 `nil` 時轉給原本的方法，否則拒絕。真正的管理器實作全部功能；替身不用改。寫入端的請求是有預設值的結構，新增 `calendarID` 欄位不影響既有程式。

## Implementation Contract

- Behavior: 見 `specs/calendar-resolution/spec.md`。
- Interface / data shape: 事件工具的輸入 schema 新增 `calendar_id`（字串）；批次建立的每一列同。`list_calendars` 每一列新增 `entity_types`（字串陣列，值為 `event`、`reminder`）。新的拒絕是 `EventKitError` 的一個新 case，訊息的文字固定在管理器的訊息表裡。
- Failure modes: 同名拒絕不寫入、不讀取；`id` 找不到回「Calendar not found」；`id` 與標題或來源不一致回一則獨立的訊息。
- Acceptance criteria: 解析器的表格測試；處理器測試（探測用的伺服器與替身）涵蓋拒絕與 `calendar_id` 選擇；`list_calendars` 列的測試；schema 測試確認每個工具宣告 `calendar_id`；沒有測試碰真實的 EventKit store。
- Scope boundaries: 見 Non-Goals。

## Risks / Trade-offs

- 讀取端原本合併的情形現在被拒絕：只影響同一帳號裡有同標題日曆的使用者，而這正是 #604 的 bug。
- 沒有 `calendar_id` 的工具遇到同名日曆時只能拒絕並建議改名；另開 issue 補上。
