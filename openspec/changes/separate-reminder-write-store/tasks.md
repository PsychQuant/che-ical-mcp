## 1. 寫入池與欄位複製

- [x] 1.1 `WriteStorePool` 與 `WriteStoreLease`（寫入池；批次共用一個 store：用 task-local 的租約）。驗證：純單元測試涵蓋上限 4、池滿拒絕、延遲佔用、釋放、失敗後換新 store、租約只佔一個名額。
- [x] 1.2 `ReminderFieldCopy`（複製的欄位是封閉列舉；複製欄位到寫入 store 上的物件，不改呼叫端）。驗證：用記憶體中的提醒事項逐欄測試，未改的鬧鐘與規則不重建，calendar 找不到時丟 store 錯誤。

## 2. 接線

- [x] 2.1 四個既有寫入 helper 改在寫入 store 上 commit，成功時長駐物件 `rollback()` 再 `refresh()`；`deleteRemindersBatch` 改走 helper 並在租約裡跑；undo 與 redo 的入口在租約裡跑（A failed write of an existing reminder or list does not stay pending in the long-lived store；One write store per call, at most four open）。驗證：source pin 測試釘住 helper 的寫入在寫入 store 上、建立與事件寫入仍在長駐 store、批次與 undo、redo 在租約裡。
- [x] 2.2 錯誤的意義：移除 may-land 錯誤與 `failed_rows_note`，加上 `writeStoreBusy` 與 `writeStoreLookupFailed`（A lookup the write store cannot answer is a store error）。驗證：錯誤訊息測試；工具描述與 manifest 一致（`ManifestParityTests`）。

## 3. 文件與實機

- [x] 3.1 `Server.swift`、`mcpb/manifest.json`、`README.md`、`README_zh-TW.md`、`CHANGELOG.md`。驗證：`swift test` 兩個時區。
- [x] 3.2 實機：單一 stdio process、名稱含 `#459` 的拋棄式清單，重現 1010 讓寫入 store 的 commit 失敗，再做一次之後的寫入，確認失敗的改動沒有落地、之後的寫入正常落地。驗證：結果記在 PR；結束後清單刪除並以 `list_calendars` 確認。2026-11-09 已做（iCloud，單一 process，以 task-local 租約注入一個會 1010 的寫入 store）：修改失敗、失敗的改動沒有落地，之後的寫入正常落地；批次第一列失敗、換 store 後第二列刪除成功、第一列保持原狀；觸發用的事件行事曆沒有殘留，寫入池最後是 0。

## 4. PR #507 第 1 輪 verify

- [x] 4.1 只寫入這次呼叫改到的欄位（呼叫端物件和自己 rollback 後比較）；日期走 `ReminderDateSync.restore` 再寫時區，鬧鐘走 `AlarmSnapshot.restore`（A failed write of an existing reminder or list does not stay pending in the long-lived store）。驗證：記憶體測試，未改的欄位保留資料庫的值、start 等於 due 的 undo、未改的鬧鐘仍是同一個物件、清單改名不寫顏色。
- [x] 4.2 存檔後從寫入 store 的物件取識別碼，不同就重新解析，`update_reminder` 的回應與 undo 紀錄用它；讀不回來是錯誤（The saved reminder is read back under the identifier it has after the save）。驗證：wiring 測試。
- [x] 4.3 批次的寫入 store 錯誤保留自己的代碼並寫 stderr，池滿在刪任何一列之前拒絕整個呼叫；失敗的 store 立刻丟掉、用到時才建新的，包在 autoreleasepool 裡，看不到資料的新 store 當成池滿（One write store per call, at most four open）。驗證：純單元測試與 wiring 測試。
- [x] 4.4 實機：單一 stdio process、名稱含 `#459` 的拋棄式清單，加做「別的 store 改了顏色後改名」與「有 URL 鬧鐘的提醒事項改鬧鐘」。2026-11-09 已做（iCloud，repo 的 release build，單一 process）：改名後保留別處改的顏色、反向也保留，但長駐 store 的快取在呼叫前已跟上別處的改動，所以這次分不出新舊寫法，過時快取只由記憶體內測試涵蓋；URL 鬧鐘用 repo build 建不出來（Swift 在 macOS 上不能設 `EKAlarm.url`，KVC 讀回 nil），改用別的 store 加的絕對鬧鐘代替，它在改鬧鐘與 undo 後都保留；1010 失敗沒有落地；批次失敗那列保留、下一列刪除；寫入池最後是 0；殘留檢查兩次都是 0。
- [x] 4.5 PR #507 第 2 輪：commit 落地但讀不回來時，先用寫入 store 副本在 commit 後的狀態記下 undo（清單記 #273 的標記）再回錯誤；undo、redo 的存檔落地但讀不回來時當作完成並在訊息說明；呼叫指名的欄位一律寫入（`requestedFields`），`update_calendar` 套用前先重讀清單；`completeReminder` 與 completion 的 undo、redo 用存檔回傳的物件。驗證：記憶體內 A/B/A 測試（提醒事項標題、清單顏色）與 wiring 測試。
- [ ] 4.6 release gate 第 6、7 步（日期經副本的順序、清單刪除）在重啟後的 session MCP 上做。
- [x] 4.8 PR #507 第 4 輪：#237 fallback 的第二次存檔在寫入 store 副本上照 `writeDueAroundStart` 的順序寫（`ReminderFieldCopy.DateOrder`，`confirmSaved` 的 `saveAgain`）；due 的變更不再指名時區；`complete_reminder` 在副本已不是讀到的場次時寫入前拒絕（`completionOccurrenceMoved`）；刪除與批次刪除的 undo 快照與「只刪已完成」判斷改取副本（`ExistingReminderSave.removal`）；release gate 第 1、2 步改成預期的拒絕；`complete_reminder` 說明寫明 `writeStoreReadBackFailed`。驗證：副本上 setter 順序的記錄測試、closure 順序測試、場次比對測試、wiring 測試。
- [x] 4.7 PR #507 第 3 輪：鬧鐘依種類（相對、絕對、位置）分成三個欄位，各自只對寫入 store 上同種類的鬧鐘做 `AlarmSnapshot.restore`；`update_reminder` 與 `complete_reminder` 的 undo 舊狀態取自寫入 store 副本在寫入欄位之前的狀態（`ExistingReminderSave.commit` 的 baseline，取第一次存檔的）；`update_calendar`、`delete_calendar` 的清單重讀失敗時回 not found；讀不回時的訊息改成「存檔沒有回錯誤」、帶新的識別碼、undo 措辭不保證還原；#237 fallback 第二次存檔落地時 stderr 不再寫「failed」。驗證：記憶體內測試（只改相對鬧鐘時保留別處加的絕對與位置鬧鐘、反向亦然；別處改的標題在寫入與 undo 後都保留）、`commit` 順序的 closure 測試、訊息測試、wiring 測試。
