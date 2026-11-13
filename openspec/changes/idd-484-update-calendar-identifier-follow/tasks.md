## 1. 規則與文字（純值）

- [x] 1.1 Requirement「Records follow an identifier this server's calendar change gave」的正向規則：`EventUpdateRecord.identifierToFollow(requestedID:identifierAfterSave:changedCalendar:wholeEvent:viaStandIn:ownOccurrenceID:)` 只在五個條件全部成立時回傳新識別碼，其餘回 nil。驗證：`EventUpdateRecordTests` 的表格測試，先寫、先看到紅，標記 `spec-example: undo-history-discard / the five conditions of the forward rewrite`（每個條件一列，各自單獨擋下改寫）。
- [x] 1.2 [P] update-undo 的回應：`EventUpdateRecord.updateUndoneText(title:newID:)` 沒有新識別碼時是現在的文字，有的時候在後面加 ` (new ID: <id>)`；標題經 `undoVisibleTitle`。驗證：`EventUpdateRecordTests` 的測試，標記 `spec-example: undo-history-discard / the answer of an update's undo with and without a new identifier`。
- [x] 1.3 [P] 合併還原的回應：`UndoKeepLaterEdits.undoneMessage(kind:title:plan:newID:)` 在保留欄位之後加同一個字尾，沒有新識別碼時逐字等於現在的文字。驗證：`UndoKeepLaterEditsTests` 的測試，標記 `spec-example: undo-history-discard / the merge answer with a new identifier`。

## 2. history 跟隨

- [x] 2.1 [P] 同一個事件的 create 紀錄與 update 紀錄隨一次改寫跟到新識別碼，另一個事件的紀錄不動，history entry 的 id 與順序不變。驗證：`EventMoveUndoTests` 的 stack 測試，標記 `spec-example: undo-history-discard / older create and update records follow one rewrite`。
- [x] 2.2 [P] 已被移到 redo stack 的 update 紀錄也隨改寫跟上。驗證：`EventMoveUndoTests` 的 stack 測試，標記 `spec-example: undo-history-discard / an update record on the redo stack follows`。
- [x] 2.3 [P] move 路徑維持 PR #469 的行為。驗證：既有的 `EventMoveUndoTests.testTheMoveAndItsUndoReportAndFollow` 加上標記 `spec-example: undo-history-discard / a move and its undo call the rewrite`，維持綠、內容不改。

## 3. 三個呼叫點

- [x] 3.1 `update_event` 在事件的第一個欄位被指派之前讀一次 `changesCalendar`，原本各自計算同一個式子的兩個拒絕改讀它。驗證：新檔 `EventUpdateFollowWiringTests` 的位置 pin（宣告在第一個指派之前、字串只出現一次），既有的拒絕測試維持綠。
- [x] 3.2 `update_event` 存檔之後、推入自己的紀錄之前，以 `changedCalendar: changesCalendar`、`wholeEvent: !hadRules || applyToAll`、`viaStandIn: resolved.viaStandIn` 與存檔前讀到的「是否為場次自己的識別碼」呼叫 `identifierToFollow`，有回傳時呼叫 `CalendarUndoManager.shared.replaceEventIdentifier`。驗證：`EventUpdateFollowWiringTests` 的順序與引數 pin。
- [x] 3.3 分裂不跟隨：決定存哪個物件的三個分支維持現狀（事件不重複與 span `all` 存解析到的物件，其餘存 `occurrence_date` 找到的場次）。驗證：`EventUpdateFollowWiringTests` 的 pin，標記 `spec-example: undo-history-discard / the saved object is picked in three branches`。
- [x] 3.4 一次性事件的 update-undo 在存檔後比對紀錄的識別碼與事件的識別碼，不同時改寫較舊的紀錄，並經 `updateUndoneText` 回應。驗證：`EventUpdateFollowWiringTests` 的順序 pin（存檔、比對、改寫、回應）。
- [x] 3.5 帶 `keep_later_edits` 的 undo 在存檔後做同樣的事，檢查與寫入之間沒有新增的 suspension。驗證：擴充後的 `UndoKeepLaterEditsWiringTests.testTheEventMergeKeepsTheUpdateArmsOrder`。
- [x] 3.6 `Sources/` 裡呼叫改寫的地方恰好五處。驗證：`EventUpdateFollowWiringTests` 對 `shared.replaceEventIdentifier(` 的次數 pin。

## 4. 公開文字與文件

- [x] 4.1 `Server.swift` 裡 `update_event`、它的 `calendar_name` 參數與 `undo` 的描述，以及 `mcpb/manifest.json` 裡 `update_event` 與 `undo` 的摘要，寫明同帳號的另一個日曆也可能給出新識別碼（在 Google 帳號內量到）、較舊的 undo entry 會跟上、這種 update 或 move 的 undo 可能以新 ID 結尾；「in four cases only」保留。驗證：`ManifestParityTests` 的新斷言（每個新句子在兩份都有，沒有角括號與 ampersand）。
- [x] 4.2 [P] `README.md` 與 `README_zh-TW.md` 的日曆那一種情況與描述一致、次數寫四種，`CHANGELOG.md` 有對應條目。驗證：三個檔案對照描述逐句讀過。
- [x] 4.3 [P] `.claude/rules/mcp-binary-version-testing.md` 的 release gate (j) 有三個順序（move、換日曆、換日曆後丟棄紀錄）。驗證：rule 檔對照下面的裝置格讀過。

## 5. 證明

- [ ] 5.1 每個條件與每個呼叫都有效：Implementation Plan 的 mutation M-a 到 M-i 逐一套用、看到指定的測試變紅、再還原。驗證：PR body 的 mutation 表。
- [ ] 5.2 其他行為沒有改變：全套 `swift test` 在 host 時區與 `TZ=UTC` 都是 0 failures，`main` 的測試名稱一個都沒少。驗證：兩次執行的摘要與移除檢查。
- [ ] 5.3 真實 store 上識別碼沒變時不改寫：兩個 iCloud 拋棄式日曆上 create、`update_event` 帶 `calendar_name`、undo、undo。驗證：裝置執行結果 `id_changed: false`、回應沒有 new ID、事件被刪除。
- [ ] 5.4 Google 帳號上紀錄會跟上：重跑 A、B、E、F、M1、M3、M4、M5 與對照組 D、G，對照計畫的「After」欄；另跑「span `future` 從第一場」那一格，必須不改寫。驗證：PR body 的裝置表。
- [ ] 5.5 跨帳號（iCloud 與 Google，兩個方向）一次性事件換日曆與它的 undo 會跟上。驗證：PR body 的裝置表。
