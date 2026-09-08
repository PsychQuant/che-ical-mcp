## Context

#198 的既有診斷提出統一格式或明確區分。兩者都回傳規則陣列；事件每條規則的欄位較少，提醒事項較完整，另有 null/[] 語意。兩者均已有使用者。

## Goals / Non-Goals

Goals：讓新用戶端能由不同欄位名稱選對解析器；既有用戶端保留舊行為。
Non-Goals：不改 recurrence 寫入 schema、不改兩者的陣列容器、不減少任一實體的規則數量、不更動日期時區格式。

## Decisions

### 明確命名與相容別名

事件新增 event_recurrence_rules，提醒事項新增 reminder_recurrence_rules。兩者分別引用原 recurrence_rules 的同一個 JSON 值，避免同一實體的別名內容漂移。這採既有診斷方案 C 的相容變體：新增欄位、不立即移除舊名稱。統一事件到提醒事項格式或反向壓縮都會破壞已部署解碼器，故不採用。

### 未知頻率防護

事件的固定陣列索引改為有邊界的 frequency name helper；未知 raw value 回傳 unknown，並另輸出 frequency_raw_value。已知值不新增該欄位，維持原事件物件的形狀。

## Implementation Contract

- 事件 standard 輸出有 recurrence_rules 時，同時回傳值相等的 event_recurrence_rules；非週期事件兩者都省略。summary 不新增這些欄位。fields 可明確選取新欄位。
- 提醒事項 list/search 同時回傳 reminder_recurrence_rules 與 recurrence_rules；非週期為 []，週期但規則無法取得為 null，否則為完整規則陣列。
- 事件 end_date 維持既有 DateFormatter；提醒事項維持 UTC instant。文件以對照表固定容器、缺值、日期與額外 selectors 差異。
- 測試固定別名 JSON 值相等、空值/空陣列、多條規則、事件 fields 選取與 summary 省略，以及未知頻率 helper。
- 驗證用記憶體值與 fake event，不寫入真實 EventKit store。

## Risks / Trade-offs

新增別名增加標準回應大小 → 事件可透過 fields 選擇所需欄位。嚴格拒絕未知欄位的解碼器仍需更新，文件明載此相容限制。

## Migration Plan

新用戶端使用各實體的新欄位；舊欄位持續支援。回退此 commit 即恢復原欄位集合，沒有資料遷移。
