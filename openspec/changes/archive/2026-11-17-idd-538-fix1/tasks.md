<!--
沒有 [P]：每個 task 都以 build 或測試結束，這台機器一次只跑一個 build（共用的 build 鎖）。
測試先寫；每個新分支與新文字拿掉時要看到對應的測試失敗（紅），記在 PR body 的 mutation 表。
-->

## 1. 規則（純值，`DeleteUndoFollow.swift`、`UndoManager.swift`）

- [x] 1.1 R5（requirement「Records follow an item the undo of its delete recreated」，第 1 到 3 節都屬於它）：`DeleteUndoFollow.decision` 在 `newID == removedID` 時回 `.none`（`.seriesWithExceptions`、`oneOffs` 大於 0）；`newID` 為 nil 仍標記。驗證：`DeleteUndoFollowTests` 的表格測試多一列，標記 `spec-example: undo-history-discard / the closed list of the follow rule`，先看到紅。
- [x] 1.2 R3：標記的集合以 `UndoOperation.notFollowedTitle` 為準（`.updateRecurringEvent` 與 `.batch` 回 nil），`markSeriesNotFollowed` 只標記、只計入 `notFollowedTitle` 非 nil 且指著該系列的紀錄。驗證：`DeleteUndoFollowHistoryTests.testMarkingFlagsTheEntriesThatNameTheSeries` 改寫成 marker 不標記、不計入，標記 `spec-example: undo-history-discard / what is flagged`。
- [x] 1.3 R4：`EventIdentifierChange`（`.sameEvent`、`.recreated`）；`replacingEventIdentifier(_:with:change:)` 與 `CalendarUndoManager.replaceEventIdentifier(_:with:change:)`，預設 `.sameEvent`（#435、#484 的五個呼叫點逐字不變），`.recreated` 時 `.updateSeries` 原樣回傳；delete 的 undo 傳 `.recreated`。驗證：stack 測試兩個 stack 都不動 `.updateSeries`，`.sameEvent` 仍跟上，標記 `spec-example: undo-history-discard / the rewrite after a recreate leaves the #263 record`。
- [x] 1.4 R3 文字與 F31：單筆句子的第二句改成「An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.」；`seriesNotFollowed` 改成「so the series this entry names no longer exists」；batch 的句子 `DeleteUndoFollow.batchNotFollowedSentence(_:)`（一個成員與多個成員）。驗證：`DeleteUndoFollowTests` 逐字比對，標記 `spec-example: undo-history-discard / the batch form`。

## 2. batch（R1）與提醒事項 batch（R2）

- [x] 2.1 `undoDeletedEvent(_:removedID:kind:)` 回傳 `notFollowed: Int?`（標記數大於 0 時的 `oneOffs`）；`UndoMemberOutcome.notFollowed: [Int]`；`UndoBatchExecution.run` 收集並交給 `batchUndoFailure`；`UndoBatchPartiallyUndoneError.restoredNotFollowed`；`undoBatch` 與 `undoBatchRestoringAvailable` 回傳它；`batchUndoneMessage(count:events:differing:notFollowed:)` 與兩種 part-way 文字以 batch 句子結尾。驗證：`undoBatchMember` 在記憶體 store 上回 `[1]`、沒有較舊紀錄時回 `[]`；`UndoBatchExecution.run` 以 `undoBatchMember` 為 restore 時回應以句子結尾、part-way 時錯誤文字以句子結尾；`batchUndoneMessage` 沒有標記時逐位元組不變；`UndoBatchWiringTests` 釘住 `undoBatch` 的組合行。
- [x] 2.2 R2：`deleteRemindersBatch` 在 `commitReminderRemoval` 之前讀 `calendarItemIdentifier`；`testTheRecordSitesReadTheRemovedIdentifierBeforeTheRemoval` 的提醒事項 batch pin 改成之前。驗證：先改 pin 看到紅，再改程式。

## 3. 測試補強（R10）

- [x] 3.1 F16：`reminderBatchDelete` 依序帶成員的識別碼。F17：偽造標題加非空 `newID`，真正的後綴在結尾引號之後。F18：每種可標記紀錄的拒絕標題、換行與超過長度上限的標題，經正式的 builder，期望值是字面字串。F19：batch 停在半途時，已寫入的成員跟上、保留的成員仍指自己的識別碼（`failingSaveTitles`）。F20：fake store 的開關讓重建的系列帶 `/RID=`，測 M25 的正規化。驗證：各測試先在拿掉對應程式時看到紅。

## 4. 文字與文件（R6–R9）

- [x] 4.0 requirement「Records follow an identifier this server's calendar change gave」：「Any other write …」一句排除 delete 的 undo（F12），規格之外沒有行為改變。驗證：`EventUpdateFollowWiringTests` 不改內容即通過，五個呼叫點逐字不變。

- [x] 4.1 `Server.swift` 的 `undo` 描述與 `mcpb/manifest.json` 的摘要：排除項、#263 紀錄不跟、「measured on iCloud」、句子只對 not found 的紀錄成立；`ManifestParityTests` 釘住範圍那一句，每個片語在文件中剛好一次，沒有角括號與 ampersand。
- [x] 4.2 README、README_zh-TW、CHANGELOG（F11、F14、F35、R4、R7）；release gate 第 3 步加 session 的 `list_events` 確認（F29），新增提醒事項 batch 一步（R2），寫明 M32 的 stand-in 形狀沒有證據到達（F20）。
- [x] 4.3 程式註解（F21、F33、F36、F37：`undoDeleteEvent` 保留，理由寫在報告）；封存的 #538 `tasks.md` 與 `proposal.md` 改正函式、測試檔與參數名（F15、F23）。

## 5. 證明

- [x] 5.1 mutation：每個新分支與每段新文字一個 mutant，看到紅再還原；表放在 PR body。
- [x] 5.2 全套 `swift test` 在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 0 failures；對 `d2704020` 與 `origin/main` 的移除測試檢查。
- [x] 5.3 iCloud（簽章 release build，一個 stdio process 一個順序，讀回用 `--cli`）：順序 1、8、9；R1 的 batch 格；R2 的提醒事項 batch 格；R4 的 #263 形狀；清理後 probecount 兩次。
