## Problem

幾輪 verify 留下的項目：文字比程式說得多或少、release gate 的文字過時、少了測試、封存紀錄寫錯，以及 v1.23.0 的 release commit 沒有合併回 `main`。五張 issue 都不要求新功能：

- **#528**：`5547876c`（`release/v1.23.0` 的頂端，帶 tag `v1.23.0`）不是 `main` 的祖先，`main` 的 `CHANGELOG.md` 把已出貨的條目列在 `[Unreleased]`，還有一個過時的 `## [1.23.0] - 2026-11-01`。
- **#547**：gate 第 11 步 edited-before 形狀最後一句還預期 edited-before 拒絕；#428 之後經系列 id 的 `delete_event` span `all` 會經那個場次把整串刪掉（2026-11-13 在 Google 量到）。
- **#554**：PR #552 第 3 輪留下的文字：`calendar_name` 的描述與 manifest 摘要把換 ID 的情況寫成封閉清單；gate (j) 只有 PR #552 裝置執行涵蓋的那句漏了三格；規格開頭一句、`EventUpdateRecord` 的註解與一個測試註解的措辭；封存的 #484 proposal 的一條 Success Criteria。
- **#555**：PR #545 第 4 輪留下的文字與紀錄：`delete_event` 的 span `future` 句沒有 #550；#549 只量過兩種形狀；「stand-in」用錯；三個工具的描述沒寫只找得到 `<series>/RID=` 形狀的場次；規格的日期規則漏了搬移列的自己時區那一天；gate 的紀錄說法；`dayReadings` 的每筆讀取沒有釘住；span `this` 的指示只在 iCloud 量過。
- **#559**：PR #556 第 2 輪留下的：move by copy 的紀錄被標記、被計數，但它的 undo 從不回答 not-followed 的文字；#428 的 update 被放進「以場次 ID 指著系列的紀錄」的限制裡（它們是 marker）；`undo` 描述與 manifest 摘要的措辭；巢狀 batch 的計數與 part-way 文字的位置沒有測試；三個 manager 層的測試放在 `*HandlerTests` 檔；測試註解與 spec-example 標記不符；封存紀錄的錯誤。

## Root Cause

- release 摺疊的 commit 留在 release branch 上，發布程序沒有寫要合併回 `main`。
- 文字在各輪改程式時沒有逐句對照量到的範圍（Google 之外沒有量、只量了兩種形狀、只在 iCloud）。
- `notFollowedTitle` 把 `.moveByCopy` 列為有標題的種類，而 move by copy 的 undo 在找不到副本時以 `MoveByCopyUndo.copyState` 回報，不經過 not-followed 的文字。

## Proposed Solution

- #528：在本分支以 merge commit 合併 `5547876c`，`[1.23.0] - 2026-11-08` 與發布時相同，`[Unreleased]` 只留 `5547876c` 之後合併的；發布程序加一句「摺疊的 commit 要合併回 `main`」。（合併帶進 CHANGELOG 以外檔案的處理，見 tasks 1.1。）
- #547、#554、#555：照各 issue 的項目改文字；#555 第 8 項加一個 `*WiringTests` 釘選。
- #559：`notFollowedTitle` 對 `.moveByCopy` 回 nil（不標記、不計數），先寫紅的測試；文字照 G6、G7、G9、G10、G15、G16、G20、G22、G25、G31、G32；第 4 節的行為不改，在規格、README、CHANGELOG 寫成限制；補 G11、G13 的測試，把四個 manager 層的測試移到 `DeleteUndoFollowBatchMemberTests`。

## Corrections to archived records（2026-11-18，本 change 記錄）

`openspec/changes/archive/` 受 archive-first 保護，hook 拒絕以 Edit 與 Write 工具修改，所以較早封存的 change 的更正寫在這裡，不改那些封存檔（本 change 自己的封存檔在 PR #562 的 verify 輪次中改過，第 2 輪是在暫時解除保護的期間改完、隨即恢復保護）：

- `2026-11-14-idd-484-update-calendar-identifier-follow/proposal.md` 的 Success Criteria「span `future` 的寫入不觸發改寫」：只對重複事件成立。一次性事件帶 span `future` 與 `calendar_name` 時，事件不重複，條件 2 成立，其餘條件也成立時會改寫（#554 第 5 項）。
- `2026-11-17-idd-538-fix1/proposal.md`（Proposed Solution 的 R1 與 Success Criteria 第一條）與 `tasks.md` 2.1 說 part-way 的文字「以 batch 句子結尾」：實際是 batch 句子放在失敗項目自己的錯誤之前，訊息以失敗項目的錯誤結尾（G8、G13）；位置現在由 `UndoBatchRestoreTests.testThePartWayTextCarriesTheBatchSentenceBeforeTheFailedItemsError` 檢查。
- `2026-11-16-idd-538-recreated-item-records-follow/tasks.md` 4.2 在 fix1 那一輪原地改寫（`shared.` 改成 `undoHistory.`），沒有加日期註記（G12）。
- `2026-11-16-idd-538-recreated-item-records-follow/proposal.md` 的 Impact 說修改的測試檔都是「機械性加上 `id`」：`EventUpdateFollowWiringTests`（呼叫點的計數 pin 從五處改成六處）、`ManifestParityTests`（新的 pin）、`SeriesExceptionsUndoTests`（新的測試）與 `UndoBatchWiringTests`（新的 pin）不只是加 `id`（G30）；同一輪的 `NewObjectSaveTests`（`restoredReminderMessage` 的 pin 要求新的 `newID`）、`DeleteUndoTests`（pin 從 `undoDeleteEvent` 移到 `recreateDeletedEvent`）與 `SeriesExceptionsUndoHandlerTests`（pin 字串與一段註解）也不只是加 `id`（2026-11-18 PR #562 verify r1 K12 補上）；`OccurrenceOriginWiringTests`（pin 從 `undoDeleteEvent` 移到 `recreateDeletedEvent`）、`UndoCalendarMissingTests`（pin 移到 `recreateDeletedEvent`，並釘住帶 `removedID` 的 `undoDeletedEvent`）、`ReminderUndoWiringTests`（`.deleteReminder` 的 pin 要求 `removedID`）與 `DetachedOccurrenceSpanTests`（batch 紀錄的 pin 改成 `.batch(undoOperations)`）也是（2026-11-22 verify r2 M5 補上）。這些是舉例，不是完整清單：那一輪改了三十多個測試檔，沒有逐一分類。
- `2026-11-17-idd-538-fix1/tasks.md` 4.0 說 `EventUpdateFollowWiringTests` 不改內容：fix1 那一輪改了它的一段註解（F21），斷言沒有改（G30）。
- `2026-11-17-idd-538-fix1/proposal.md` 的 Impact 列了 `NewObjectSaveTests` 與 `UndoBatchRestoreTests`，那一輪沒有改它們；漏了改過的 `DeleteUndoTests` 與 `UndoBatchPartialRestoreTests`（G33）。

## Verify round 1（2026-11-18，PR #562）

- #528：`main` 開了 required linear history，merge commit 要管理員略過；PR 改成照現狀 squash 也對（內容正確），tag 能不能從 `main` 走到留給維護者決定，#528 保持開著。Proposed Solution 與 tasks 1.2 要加進發布程序的那一句（兩份 README）已改寫成：打 tag 之前在 `main` 上經 PR 摺疊 `[Unreleased]`（v1.20.0 到 v1.22.0 的做法）。Proposed Solution 與 tasks 1.2 本身保留提案時的寫法（「以 merge commit 合併 `5547876c`」「合併回 `main`」），那是提案當時的計畫，不是現在的做法。（這兩句的措辭於 2026-11-22 verify r2 M13 更正。）
- 其餘修正見 PR #562 的 Verify-fix (round 1) 留言。

## Verify round 2（2026-11-22，PR #562）

- #528 的祖先：第 1 輪給維護者的做法「合併 `5547876c`、衝突一律取 `main` 這邊」不對（M1、M2）：git 合併 `CHANGELOG.md` 時沒有衝突，卻在 `[Unreleased]` 底下多插一個 `[1.23.0]` 標題。正確的是 squash 之後 `git merge -s ours 5547876c`，合併後 `git diff HEAD^1 HEAD` 是空的；另一條路是用 merge commit 合併 PR #562 本身，不必解衝突。兩條都需要管理員略過 required linear history。
- 發布程序（兩份 README）重寫成依序三步：在 `main` 上經 PR 升版本號並摺疊兩份 changelog；checkout 那個合併 commit、從它 build；在同一個 commit 上打 tag（`gh release create --target <完整 SHA>`，或先用 git 建 tag 再帶 `--verify-tag`）（D1、M33）。另寫要發布的點落後 `main` 的 HEAD 時怎麼辦，以及 v1.23.0 是怎麼變成這樣的（PR #370 摺疊後沒有打 tag，之後從 `7947921` 開 branch 切出）（M25）。`gh` 的兩個參數只對照 `gh release create --help`，沒有執行。
- `-s ours` 的做法與用 merge commit 合併 PR 的做法，都在一個停用 push 的 scratch clone 上模擬過（squash 用 `git commit-tree` 建出）：`-s ours` 之後 `git diff HEAD^1 HEAD` 是空的，`5547876c` 成為祖先；用 merge commit 合併 PR 沒有衝突，樹與 PR head 相同；`-X ours` 則在 `CHANGELOG.md` 多出第二個 `[1.23.0]`。管理員略過本身沒有執行，只讀了 protection API（`required_linear_history` 開、`enforce_admins` 關）。
- 本 change 的兩份 delta spec 對齊 main spec，逐個 requirement 比對（去掉 trace 註解）沒有差異：補上第 1 輪直接寫進 main spec 的 #426 條件（M3、M12），以及這一輪的修改：單筆拒絕給 ID 的條件（D5）、「不寫原本的日期」（M11）、#263 紀錄何時被標記（D9）、#426 的 undo 先讀日曆（D10）、move by copy 的 undo 先還原再查副本（M23、D8）。
- tasks 1.2 的「驗證：文件測試通過」：沒有測試讀這一句（M32），驗證是對照 git 與 branch protection 的讀取，見 tasks 1.2 的註記。
- 其餘修正見 PR #562 的 Verify-fix (round 2) 留言。

## Non-Goals

- 執行期的回應文字不改（#559 G6 的單筆句子、G39 的 part-way 相鄰兩句）：那些字串逐字寫在規格裡，裝置紀錄也是這些字。例外有兩個：#555 第 2 項點名的 `leftBehind`，照該項改；以及 move by copy 的 undo 找不到副本時的回答（`MoveByCopyUndo` 的 `.notFound`），verify 第 1 輪（K15）多寫一個原因，第 2 輪（M10）把它收窄到真的會找不到的那種情形（2026-11-22 verify r2 M8、M14、M18 補上）。
- #559 第 4 節的行為（R7、G19、日曆也不見時先回日曆的拒絕、F38、F39、M32）：寫成限制或列入後續 issue，不改。
- #559 第 6 節（#538 出版前的 gate）。
- 任何裝置執行：只有 `.moveByCopy` 的選擇改行為，它拿掉一個標記，不需要裝置格。

## Success Criteria

- 每一句改過的文字對程式成立、不比程式寬；`ManifestParityTests` 與文件測試的每個釘選片語在它的文件裡剛好出現一次；manifest 的顯示字串沒有角括號與 ampersand。
- `.moveByCopy` 的測試先紅後綠；每個新測試各有一個 mutant 看到紅。
- 整套 `swift test` 在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 failures；依（檔案、名稱）對 `origin/main` 列出移除與搬移的測試。

## Impact

- Affected specs: `undo-history-discard`（修改 2 個 requirement）、`edited-occurrence-addressing`（修改 2 個 requirement）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/UndoManager.swift`（`notFollowedTitle`）
  - `Sources/CheICalMCP/Server.swift`、`mcpb/manifest.json`
  - 註解：`Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`（含 `leftBehind` 的文字）、`EventUpdateRecord.swift`、`EventKitManager.swift`
  - `Tests/CheICalMCPTests/`：`ManifestParityTests`、`EditedOccurrenceAddressTests`、`EditedOccurrenceAddressWiringTests`、`EventUpdateRecordTests`、`DeleteUndoFollowHistoryTests`、`DeleteUndoFollowHandlerTests`、`DeleteUndoFollowBatchMemberTests`（新檔）、`UndoBatchRestoreTests`、`SeriesExceptionsUndoTests`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`
  - #528 的合併：`plugin/CHANGELOG.md`、`plugin/README.md`（2026-11-18 PR #562 verify r1 K13 補上）
  - verify 第 1 輪的修正：`CLAUDE.md`（測試命名表加 manager 層一列）、`Sources/CheICalMCP/EventKit/MoveByCopyUndo.swift`（副本找不到的原因多一個）、`Tests/CheICalMCPTests/MoveByCopyUndoTests.swift`、`Tests/CheICalMCPTests/DeleteUndoFollowHistoryTests.swift`（註解）
  - verify 第 2 輪的修正：`plugin/skills/quota/SKILL.md`（#333 在 v1.23.0 就已出貨）、`Tests/CheICalMCPTests/DeleteUndoFollowHistoryTests.swift`（一個新測試）、`Tests/CheICalMCPTests/DeleteUndoFollowHandlerTests.swift`（註解）；其餘是上面已列的檔案
