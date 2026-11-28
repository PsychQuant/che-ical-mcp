## 1. 解析器

- [x] 1.1 先寫測試：測試 A name and source that match more than one calendar are refused 的純函式部分——以假的日曆型別對「兩個同標題同來源」「跨來源同標題」「一個符合」「沒有符合」「大小寫不同」逐列判定，並測 candidate id 的格式檢查（含空白的 id 時不列）。測試檔帶標記 `spec-example: calendar-resolution / two calendars in one account are refused` 與 `spec-example: calendar-resolution / a refusal names ids and no titles`；先看到它失敗。
- [x] 1.2 實作 一個純的泛型解析器，管理器的兩個查找函式共用（`Sources/CheICalMCP/EventKit/CalendarResolution.swift`）：標題、來源、`id` 輸入，`found`／`notFound`／`idMismatch`／`ambiguousAccounts`／`ambiguousInAccount` 輸出；驗證：1.1 的測試通過。
- [x] 1.3 先寫測試並實作 `id` 優先，且與標題、來源不一致就拒絕：`id` 只在候選裡找，與給定的標題或來源不符時回 `idMismatch`。測試檔帶標記 `spec-example: calendar-resolution / calendar_id against name and source`；驗證：該測試的每一列通過。

## 2. 管理器與錯誤

- [x] 2.1 `EventKitError` 新增同名拒絕的 case，訊息依 新的拒絕訊息依工具有沒有 `calendar_id` 而不同 分兩種文字，並符合 拒絕訊息只放候選的 `id`（不含標題與來源標題）；驗證：錯誤訊息測試斷言兩種文字、`id` 列出與不列、不含標題。
- [x] 2.2 `findCalendar` 與 `findCalendars` 改用解析器：標題加來源符合不只一個時讀取端與寫入端一律拒絕；只有一個符合時結果與以前相同；`calendarID` 與 `offersID` 兩個參數預設為 `nil` 與 `false`；驗證：更新 `CalendarNameMatchTests` 裡釘住這兩個函式的測試，並新增一個測試確認兩者呼叫同一個解析器。
- [x] 2.3 `listEvents`、`searchEvents`、`checkConflicts`、list_events_quick 使用的讀取函式、`createEvent`、`updateEvent` 接受 `calendarID` 並傳給查找函式；驗證：編譯通過，既有的測試不變。

## 3. 來源協定與處理器

- [x] 3.1 依 不改現有協定的簽名：`EventRangeReadSource` 新增帶 `calendarID` 的要求並在協定擴充裡給預設實作（`calendarID` 為 `nil` 時轉給原方法，否則拒絕）；`EventWriteSource` 的建立與更新請求新增 `calendarID` 欄位；驗證：既有的十二個測試檔不改就能編譯，並有一個測試確認預設實作在 `calendarID` 有值時拒絕。
- [x] 3.2 `list_events`、`list_events_quick`、`search_events`、`check_conflicts`、`create_event`、`update_event`、`create_events_batch`（每一列）宣告並解析 `calendar_id`（字串；型別不對時被引數檢查拒絕），符合 calendar_id selects one calendar；驗證：schema 測試確認每個工具與批次列都宣告 `calendar_id`。
- [x] 3.3 處理器測試（替身，不碰真實 store）：`calendar_id` 傳到讀取與寫入來源、型別不對時被拒絕、拒絕訊息的兩種文字。（更正，verify 第 1 輪：這個 change 沒有寫「同名拒絕、不一致、另一種類型的 `id`」的處理器測試；這三種情形在 `idd-604-fix1` 以 `CalendarLookup.one` 的測試覆蓋。）

## 4. list_calendars

- [x] 4.1 符合 list_calendars says which kind each row is：`CalendarReadValue` 新增 `entityTypes`，`listedRow` 輸出 `entity_types`；驗證：測試帶標記 `spec-example: calendar-resolution / entity types of a row`，其他欄位不變。

## 5. 文件

- [x] 5.1 README 與 README_zh-TW 的工具說明、`CHANGELOG.md` 與 `changelog/` 的紀錄寫明新的拒絕與 `calendar_id`；驗證：文件測試（若該 repo 有）通過，否則目視確認。（更正：只更新了根目錄的 `CHANGELOG.md`；`changelog/` 是停在舊版本的檔案，沒有動。）
- [x] 5.2 跑 `swift test` 全部通過，且沒有新增測試讀寫真實的 EventKit store（用 `TestStoreIsolation` 相關測試確認）。
