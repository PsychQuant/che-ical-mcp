## Problem

PR #556（#538）第一輪 verify 回了 41 項（7 個 MEDIUM），沒有任何一項是錯誤的寫入或刪除，但規格、公開文字與程式在幾個地方不一致，另有一行讀取順序：

- **batch 的 undo 不說**：batch 的成員經 `undoDeletedEvent` 標記了較舊的紀錄，但 batch 的回應只由數字與 outcome 組成，沒有「較舊的紀錄沒有跟上」那一句；規格、README、CHANGELOG 都說 delete 的 undo 會說（F1、F4、F24、F27）。
- **提醒事項 batch 在移除之後才讀識別碼**：`deleteRemindersBatch` 在 `commitReminderRemoval`（commit、`rollback()`、`refresh()`）之後才讀 `calendarItemIdentifier`，單筆的 `deleteReminder` 是在移除之前讀；測試名稱說「之前」，釘的卻是之後（F2、F6、F28）。
- **marker 被標記**：`.updateRecurringEvent` 的 undo 在查找之前就被拒絕並丟棄，但它被標記、被算進句子的數字，句子說它只能用 `discard_id` 放棄（F3、F8、F25、F41）。
- **#263 的整串修改紀錄跟上了也一定被拒絕**：`.updateSeries` 跟上之後保留舊系列的 external identifier，undo 一定以 `.identity` 拒絕（F7、F30）。
- **`.flag` 不看新的識別碼**：重建的系列沿用被刪的識別碼時，句子預告的拒絕不會出現（F26）。
- **文字**：manifest 摘要沒有排除項、沒有「在 iCloud 量的」（F5、F22）；名稱帶 `/RID=` 的紀錄不跟也不標記，沒有寫出來（F9）；規格把新識別碼寫成 store 的事實（F10）、#484 的「其他寫入不移動紀錄」沒有排除 delete 的 undo（F12）、情境的 WHEN 比規則寬（F13）、拒絕文字預設重建的系列還在（F31）；提醒事項的回應不一定以新 ID 結尾（F11）；跟上的紀錄也會因重建或本 server 的完成而被拒絕（F14）；過時的註解與紀錄（F15、F21、F23、F33、F35、F36、F37）；release gate 第 3 步少了跨 process 的確認（F29）。
- **測試缺口**：F16 到 F20。

## Root Cause

- `UndoMemberOutcome` 只帶文字、`differing` 與 `events`；句子加在成員文字上，而 batch 不讀成員文字。
- 提醒事項 batch 的紀錄點寫成「讀迴圈裡查到的物件」，位置在移除之後。
- `markSeriesNotFollowed` 用的是 `eventIdentifiersNamed`，這是事件改寫（#435、#484）的集合，不是「undo 會查找這個系列」的集合。
- delete 的 undo 呼叫的是 #435／#484 共用的 `replaceEventIdentifier`，那裡 `.updateSeries` 會跟上；那條規則適用於同一個事件換了識別碼，不適用於重建出來的新事件。
- `DeleteUndoFollow.decision` 的 `.flag` 分支沒有比 `newID` 與 `removedID`。

## Proposed Solution

- **R1**：`UndoMemberOutcome` 帶 `notFollowed: [Int]`（每個標記了較舊紀錄的事件成員的 `oneOffs`），經 `UndoBatchExecution.run`、`undoBatch`、`batchUndoFailure`、`UndoBatchPartiallyUndoneError`、`UndoBatchPartialRestoreStoppedError` 傳上去；`batchUndoneMessage` 與 part-way 的文字以 batch 的句子結尾（一個成員與多個成員各一種說法，`oneOffs` 加總）。
- **R2**：`deleteRemindersBatch` 在 `commitReminderRemoval` 之前讀識別碼，與 `deleteReminder` 相同；pin 改成之前、測試名稱與內容一致。
- **R3**：標記的集合改成獨立的窮舉（`UndoOperation.notFollowedTitle` 非 nil 的種類）：`.updateRecurringEvent` 與 batch 不標記、不計數。單筆的句子改成「An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.」，只對 undo 會查找系列的紀錄成立。
- **R4**：delete 的 undo 改走 `replaceEventIdentifier(_:with:change: .recreated)`：`.updateSeries` 不跟上（#435、#484 的五個呼叫點不變，仍跟上）；它的 undo 回 not found、保留、`discard_id` 放棄，系列在標記形狀時被標記。
- **R5**：`decision` 在 `newID == removedID` 時回 `.none`。
- **R6–R9**：manifest 摘要、`undo` 描述、規格、兩份 README、CHANGELOG、release gate、封存的 #538 `tasks.md` 與程式註解照裁定改寫；`undoDeleteEvent` 保留並改正註解（PR #558 的新測試呼叫它，移除會讓後合併的 PR 編譯失敗）。
- **R10**：補 F16 到 F20 的測試；M25 以 fake store 的開關測行為；M32（stand-in）記憶體 store 做不出來，在 gate 寫明沒有證據到達。

## Non-Goals

- 名稱帶 `/RID=` 的紀錄的跟隨與標記（R7，列入後續 issue）。
- `undoHistory` seam 只做一半、`isSeriesNotFollowed` 編進 release（F38、F39，列入後續 issue）。
- 被標記的 update 或 move 紀錄在日曆也不見時先回日曆不見的拒絕（列入後續 issue）。
- move by copy 的副本被標記（F41：走不到）。
- 經 handler 跑完整 batch undo 的測試：batch 在第一個寫入前讀真實日曆（#248 B），記憶體 store 給不了；改以 `undoBatchMember` 加 `UndoBatchExecution.run` 測，並釘住 `undoBatch` 的組合那一行。

## Success Criteria

- batch 的成員是單獨改過場次回成獨立事件的系列、而較舊紀錄被標記時，batch 的回應與 part-way 的文字以 batch 的句子結尾；沒有標記時文字逐位元組不變。
- `.updateRecurringEvent` 不被標記、不計入；`.updateSeries` 在 delete 的 undo 不跟上、在 #435／#484 的改寫仍跟上。
- `newID == removedID` 時不標記。
- 每個新分支與每段新文字各有一個 mutant，看到紅。
- 整套測試在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 failures。
- iCloud 裝置格：順序 1、8、9，R1 的 batch、R2 的提醒事項 batch、R4 的 #263 形狀。

## Impact

- Affected specs: `undo-history-discard`（修改 2 個 requirement）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/DeleteUndoFollow.swift`
  - `Sources/CheICalMCP/EventKit/DeleteUndo.swift`
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`
  - `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`
  - `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`
  - `Sources/CheICalMCP/EventKit/UndoBatchRestore.swift`
  - `Sources/CheICalMCP/EventKit/UndoBatchPartialRestore.swift`
  - `Sources/CheICalMCP/EventKit/UndoGuardErrors.swift`
  - `Sources/CheICalMCP/EventKit/UndoManager.swift`
  - `Sources/CheICalMCP/Server.swift`、`mcpb/manifest.json`
  - `Tests/CheICalMCPTests/`：`DeleteUndoFollowTests`、`DeleteUndoFollowHistoryTests`、`DeleteUndoFollowHandlerTests`、`DeleteUndoFollowWiringTests`、`EventUpdateFollowWiringTests`、`ManifestParityTests`、`NewObjectSaveTests`、`ReminderBatchDeleteUndoTests`、`UndoBatchWiringTests`、`UndoBatchRestoreTests`、`SeriesExceptionsUndoTests`、`Helpers/FakeSeriesExceptionsStore.swift`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`
  - `openspec/changes/archive/2026-11-16-idd-538-recreated-item-records-follow/tasks.md`、`proposal.md`
