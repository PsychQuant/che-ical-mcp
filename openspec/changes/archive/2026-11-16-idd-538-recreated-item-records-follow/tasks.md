## 1. 紀錄記下被刪的識別碼（機械性，行為不變）

- [x] 1.1 `.deleteEvent` 與 `.deleteReminder` 改成 `.deleteEvent(id:snapshot:)`、`.deleteReminder(id:snapshot:)`，`id` 沒有預設值；`Sources/` 與測試裡每一處比對與建立都跟著改。紀錄點：`DeletedEventSnapshots.record(for:)`（一次性事件記 `eventIdentifier`，有規則的記系列不帶 `/RID=` 的識別碼）、`deleteEventSeries`、`deleteEventSeriesBatch`、`deleteReminder` 與提醒事項 batch（在移除之前讀 `calendarItemIdentifier`）。`replacingEventIdentifier` 明列 `.deleteEvent` 並原樣回傳。驗證：全套測試綠，測試數與改動前相同；commit 獨立。（commit `18dbdda6`；那個 tree 上全套 3255 個測試，修正 `NewObjectSaveTests` 的兩個 regex pin 後該類別 30 個 0 failures；batch 的事件陣列改名 `undoOperations`，`UndoBatchWiringTests` 與 `DetachedOccurrenceSpanTests` 的 pin 隨之改寫。）

## 2. 規則與文字（純值）

- [x] 2.1 Requirement「Records follow an item the undo of its delete recreated」的封閉清單：`DeleteUndoFollow.identifierToFollow(removedID:newID:isOccurrenceRecord:outcome:)`。驗證：`DeleteUndoFollowTests` 的表格測試，先寫、先看到紅，標記 `spec-example: undo-history-discard / the closed list of the follow rule`，每一列一個斷言。
- [x] 2.2 [P] 兩段文字：`DeleteUndoFollow.notFollowedSentence(oneOffs:)`（2026-11-17 更正：原本寫成 `count:`） 與 `UndoTargetMissingError.seriesNotFollowed(title:)`，只含固定字、數字與經 `undoShownTitle` 的標題。驗證：`DeleteUndoFollowTests` 逐字比對，含引號與隱藏字元的標題。（`seriesNotFollowed(title:)` 放在 `UndoGuardErrors.swift`，因為只有那裡能用 `UndoTargetMissingError` 的 private 初始化。）
- [x] 2.3 [P] 提醒事項 delete 的 undo 回應加 ` (new ID: <id>)`，沿用 `EventUpdateRecord.newIdentifierSuffix`，位置在 store 差異說明之前。驗證：`DeleteUndoFollowTests` 對 `restoredReminderMessage` 的逐字比對。

## 3. history 的改寫與旗標

- [x] 3.1 [P] 事件改寫：同一事件的 create／update 紀錄跟上，持有同一字串的 `.deleteEvent` 紀錄在 undo 與 redo 兩個 stack 都不動。驗證：`DeleteUndoFollowHistoryTests` 的 `testOlderRecordsFollowAndTheDeleteRecordKeepsTheRemovedIdentifier` 與 `testADeleteRecordOnTheRedoStackKeepsTheRemovedIdentifier`（2026-11-17 更正：原本寫成 `EventMoveUndoTests`，那個檔沒有改）。
- [x] 3.2 [P] 提醒事項改寫：`UndoOperation.replacingReminderIdentifier`、`CalendarUndoManager.replaceReminderIdentifier`，涵蓋 `createReminder`、`updateReminder`、`completeReminder`、`completeRecurringReminder`（`ReminderCompletionSnapshot.replacingIdentifier`，其餘欄位不變）與 batch 成員；`.deleteReminder` 與事件紀錄原樣回傳。驗證：新的 stack 測試，標記 `spec-example: undo-history-discard / the reminder rewrite and the event rewrite stay apart`。
- [x] 3.3 旗標：`UndoRecord.seriesNotFollowed`，`narrowed(to:)` 保留；`CalendarUndoManager.markSeriesNotFollowed(_:) -> Int` 在兩個 stack 標記指著該系列的紀錄（delete 紀錄除外）並回傳數目；`restoreFailedUndo`、`popUndo`、`popRedo` 保留旗標，`discardUndo` 一起移除。驗證：stack 測試。

## 4. 呼叫點

- [x] 4.1 `SeriesExceptionsUndo.undoDeleteEvent` 回傳重建事件的識別碼（slot 已被佔住時為 nil），在 exceptions 還原之後讀。驗證：`SeriesExceptionsUndoTests` 的記憶體 store 測試。（新的 `recreateDeletedEvent` 回傳識別碼，`undoDeleteEvent` 保留原本的兩個回傳值；測試放在 `SeriesExceptionsUndoTests`。）
- [x] 4.2 `EventKitManager.undoDeletedEvent(_:removedID:kind:)`（`removedID` 是必填的 `String?`）在 arm 回傳之後問 `identifierToFollow`，跟隨時呼叫 `undoHistory.replaceEventIdentifier`；`oneOffs` 大於 0 時呼叫 `undoHistory.markSeriesNotFollowed`，數目大於 0 才加說明句。單一 arm 與 batch 成員都經過它，move-by-copy 傳 `nil`；`undoDeletedOccurrence` 不改寫。驗證：新檔 `DeleteUndoFollowWiringTests` 的順序 pin 與 `.replaceEventIdentifier(`（任何 receiver）共六處的次數 pin（`EventUpdateFollowWiringTests` 的五處 pin 同一個 commit 改成六處）。（呼叫在 `undoHistory` 上，`EventKitManager` 新增的 seam，正式環境是 `CalendarUndoManager.shared`；`EventUpdateFollowWiringTests` 的次數 pin 改成任何 receiver 共六處。handler 測試在記憶體 store 上實際跑跟隨。）
- [x] 4.3 `restoreDeletedReminder(_:removedID:)` 在 `saveNewReminder` 回來之後呼叫 `undoHistory.replaceReminderIdentifier` 並回傳新識別碼；單一 arm 與 batch 成員都經過它。驗證：`DeleteUndoFollowWiringTests` 的順序 pin，`.replaceReminderIdentifier(` 一處（2026-11-17 更正：呼叫在 `undoHistory` 上，pin 數的是 `.replaceReminderIdentifier(`，不是 `shared.`）。
- [x] 4.4 `handleUndo`：begin 的紀錄帶旗標、而 undo 丟出 `UndoTargetMissingError` 時，照舊把紀錄放回，改丟 `seriesNotFollowed` 的文字。驗證：`DeleteUndoFollowHandlerTests` 的 handler 測試（2026-11-17 更正：原本寫成 `DeleteUndoHandlerTests`，那個檔只有 `id:` 的機械性修改）（帶旗標回專用文字、紀錄 id 不變；不帶旗標回一般 not found；丟棄後不再出現，標記 `spec-example: undo-history-discard / the flag goes with its entry`），以及 stderr 沒有寫入。
- [x] 4.5 Requirement「Records follow an identifier this server's calendar change gave」的第一句改成只講換日曆的寫入，並指向本 change 的 requirement；它的五個呼叫點與行為不變。驗證：`EventUpdateFollowWiringTests` 除了次數 pin 由五改六之外維持綠、內容不改（2026-11-17 更正：次數 pin 的字串也改了，由 `shared.replaceEventIdentifier(` 改成任何 receiver 的 `.replaceEventIdentifier(`）。

## 5. 公開文字與文件

- [x] 5.1 `Server.swift` 的 `undo` 描述與 `mcpb/manifest.json` 的 `undo` 摘要，在 #484 那句之後加一句：delete 的 undo 以新識別碼重建，較舊的紀錄跟上，例外是單獨改過的場次回成獨立事件的系列。驗證：`ManifestParityTests` 釘住兩處各自的句子、各恰好一次；沒有角括號與 ampersand。
- [x] 5.2 [P] `README.md`、`README_zh-TW.md` 的 undo 段與描述一致，`CHANGELOG.md` 的 `[Unreleased]` 有條目，寫明量過什麼、在哪裡量、什麼沒量。驗證：逐句對照描述讀過。
- [x] 5.3 [P] `.claude/rules/mcp-binary-version-testing.md` 新增 release gate「delete 的 undo 之後較舊的紀錄（#538）」：重啟後的 session MCP 上做順序 1、2、8、9 與循環提醒事項那一格。驗證：對照裝置格讀過。

## 6. 證明

- [x] 6.1 每個新分支與每段新文字都有一個 mutant，看到紅再還原。驗證：PR body 的 mutation 表（2026-11-17 更正：當時的 PR body 沒有表，只有一句話，並把只靠 source pin 的 mutant 數成五個；實際是六個，見 Implementation Complete。idd-538-fix1 補上了表）。
- [x] 6.2 全套 `swift test` 在 host 時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 failures；對 `origin/main` 的移除測試檢查列出每一個移除或改寫的測試與理由。驗證：三次執行的摘要。
- [x] 6.3 iCloud 拋棄式日曆與清單（名稱含 `#538`）上，以簽章的 release build、一個長駐 stdio process 做順序 1 到 9、batch、部分還原的 batch、循環提醒事項，對照 Implementation Plan 的「After」欄；讀回用另一個 `--cli` process。驗證：PR body 與 Implementation Complete 的裝置表。
