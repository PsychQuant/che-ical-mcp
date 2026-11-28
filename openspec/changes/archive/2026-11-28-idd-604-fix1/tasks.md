## 1. 阻擋項

- [x] 1.1 先寫測試，再改：查找與拒絕的轉換成為純函式 `CalendarLookup.one`（候選由依實體類型的 closure 取得），測試覆蓋 A name and source that match more than one calendar are refused 的每個 Example（`two calendars in one account are refused`、`a refusal names ids and no titles`、`two accounts without a source keep the earlier refusal`）；驗證：`CalendarResolutionTests` 通過。
- [x] 1.2 `listEvents`、`searchEvents`、`checkConflicts` 的 `offersID` 改為參數、預設 `false`，三個 range read 傳 `true`；批次刪除的列事件因此建議改名（`the remedy follows the tool`）；驗證：呼叫點的 source pin 在修正前的 commit 上失敗、修正後通過。
- [x] 1.3 list_calendars says which kind each row is：讀哪些清單由純函式決定，列的 `entity_types` 是讀自的清單；驗證：`entity types of a row` 的測試通過。
- [x] 1.4 calendar_id selects one calendar：另一類型的 `id` 與空字串回找不到；驗證：`calendar_id against name and source` 的每一列通過。

## 2. 其他

- [x] 2.1 `id` 格式檢查改用 code point；管理器的三個 `calendarID:` 簽名以 source pin 固定；驗證：新增的測試通過。
- [x] 2.2 更新工具描述、`plugin/skills/calendar-management/SKILL.md`、README 兩份、`CHANGELOG.md`、`docs/DESIGN_PRINCIPLES.md`；驗證：`swift test` 全部通過。
