## Context

#274 讓這類失敗的寫入至少會說「可能還會落地」，因為唯一能丟掉它的 `reset()` 會波及其他呼叫。#459 的 Diagnosis 量了三個選項需要的事，維護者 2026-11-09 決定採用選項 3：寫入池上限 4、批次呼叫共用一個 store、提醒事項的 undo 與 redo 一起搬、建立與事件寫入留在長駐 store、寫入 store 找不到物件時回報 store 錯誤。

## Decisions

### 複製欄位到寫入 store 上的物件，不改呼叫端

四個既有寫入 helper（`saveExistingReminder`、`removeExistingReminder`、`saveExistingCalendar`、`removeExistingCalendar`）已經是所有修改、完成、刪除、undo、redo 的共同出口，所以改在 helper 裡做，呼叫端不動。helper 用識別碼在寫入 store 上取出同一個物件，把長駐物件上的欄位複製過去後 commit。實測（2026-11-09，iCloud，單一 process）：

- 長駐物件上沒存的改動，不會被長駐 store 之後的 commit 帶進去，`rollback()` 會把它還原；
- 寫入 store commit 之後，長駐物件 `rollback()` 再 `refresh()`，立即讀到新的值；刪除後 `refresh()` 回 false、用識別碼也查不到；清單改名同樣立即可見；
- 重複提醒事項在寫入 store 上完成時，照常滾到下一次，長駐 store 立即讀到滾動後的狀態與完成的那一筆；
- 把長駐物件的 `EKAlarm` 直接指派給寫入 store 的物件會讓 process 終止，`EKRecurrenceRule` 用 `copy()` 也一樣：所以鬧鐘與重複規則都以相同的值建成新的物件。

### 複製的欄位是封閉列舉

提醒事項：`title`、`location`、`notes`、`url`、`timeZone`、`startDateComponents`、`dueDateComponents`、`priority`、`isCompleted`、`completionDate`、`alarms`、`recurrenceRules`、`calendar`。清單：`title`、`cgColor`。只有值不同的欄位才寫，鬧鐘與規則以值比較，避免每次都重建它們。`calendar` 用識別碼在寫入 store 上找；找不到是 store 錯誤。

### 寫入池

上限 4，在第一次真的需要寫入 store 時才佔一個名額，結束時釋放。池滿時拒絕（`writeStoreBusy`），不等待：helper 是同步的，單一呼叫在 commit 前後沒有 suspension，所以平常同時只會用到一個；只有跨 `await` 的批次會佔著名額。加上長駐 store 與另外兩個既有的 store，最多 7 個，低於實測的 10。

### 批次共用一個 store：用 task-local 的租約

批次呼叫在一個 `@TaskLocal` 租約裡跑，helper 有租約就用它的 store。租約綁在 task 上，不是共用的屬性，所以 actor 重入時，別的請求不會拿到同一個 store。租約裡任一次寫入丟出錯誤，就換一個新的 store，失敗的改動不會被下一列帶進去。

### 錯誤的意義

寫入 store 上的失敗不會落地，所以四個「may land」錯誤與批次的 `failed_rows_note` 移除，改成一般的失敗回報（經過 sanitizer 的代碼）。建立的 #237 補存仍在長駐 store 上，它的 log 仍說可能落地；undo 拒絕訊息裡「this server's failed write that landed later」也因此保留。

## Risks / Trade-offs

- 每次寫入多約 45 ms（多半是新 store 的第一次 calendar 查詢）。
- 欄位清單漏了某個欄位，就會安靜地沒寫到：清單是封閉的，測試逐欄釘住，新增欄位時要一起加。
- 池滿時呼叫被拒絕；實務上只有多個跨 `await` 的批次同時進行才會發生。
