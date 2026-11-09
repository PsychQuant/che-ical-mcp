## 1. 寫入池與欄位複製

- [x] 1.1 `WriteStorePool` 與 `WriteStoreLease`（寫入池；批次共用一個 store：用 task-local 的租約）。驗證：純單元測試涵蓋上限 4、池滿拒絕、延遲佔用、釋放、失敗後換新 store、租約只佔一個名額。
- [x] 1.2 `ReminderFieldCopy`（複製的欄位是封閉列舉；複製欄位到寫入 store 上的物件，不改呼叫端）。驗證：用記憶體中的提醒事項逐欄測試，未改的鬧鐘與規則不重建，calendar 找不到時丟 store 錯誤。

## 2. 接線

- [x] 2.1 四個既有寫入 helper 改在寫入 store 上 commit，成功時長駐物件 `rollback()` 再 `refresh()`；`deleteRemindersBatch` 改走 helper 並在租約裡跑；undo 與 redo 的入口在租約裡跑（A failed write of an existing reminder or list does not stay pending in the long-lived store；One write store per call, at most four open）。驗證：source pin 測試釘住 helper 的寫入在寫入 store 上、建立與事件寫入仍在長駐 store、批次與 undo、redo 在租約裡。
- [x] 2.2 錯誤的意義：移除 may-land 錯誤與 `failed_rows_note`，加上 `writeStoreBusy` 與 `writeStoreLookupFailed`（A lookup the write store cannot answer is a store error）。驗證：錯誤訊息測試；工具描述與 manifest 一致（`ManifestParityTests`）。

## 3. 文件與實機

- [x] 3.1 `Server.swift`、`mcpb/manifest.json`、`README.md`、`README_zh-TW.md`、`CHANGELOG.md`。驗證：`swift test` 兩個時區。
- [x] 3.2 實機：單一 stdio process、名稱含 `#459` 的拋棄式清單，重現 1010 讓寫入 store 的 commit 失敗，再做一次之後的寫入，確認失敗的改動沒有落地、之後的寫入正常落地。驗證：結果記在 PR；結束後清單刪除並以 `list_calendars` 確認。2026-11-09 已做（iCloud，單一 process，以 task-local 租約注入一個會 1010 的寫入 store）：修改失敗、失敗的改動沒有落地，之後的寫入正常落地；批次第一列失敗、換 store 後第二列刪除成功、第一列保持原狀；觸發用的事件行事曆沒有殘留，寫入池最後是 0。
