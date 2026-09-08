## 1. 契約與測試

- [x] 1.1 Entity-specific recurrence read names：先新增失敗測試，核對事件別名、fields/summary 與提醒事項 []/null/多規則語意。
- [x] 1.2 Unknown event frequency：新增 frequency raw value 999 的失敗測試，確認不會陣列越界。

## 2. 實作與文件

- [x] 2.1 明確命名與相容別名：新增 event_recurrence_rules、reminder_recurrence_rules 並共用原 JSON 值；以 1.1 測試驗證。
- [x] 2.2 未知頻率防護：以安全 helper 取代事件頻率索引，未知值輸出原始整數；以 1.2 測試驗證。
- [x] 2.3 Published format distinction：README 中英版與 REMINDER_RECURRENCE.md 記載容器、缺值、日期、selector 差異及遷移限制；逐項對照 design 檢查。

## 3. 驗證

- [x] 3.1 執行完整 swift test、git diff --check、spectra validate，將實際結果寫入 issue #198。
