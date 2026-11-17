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

`openspec/changes/archive/` 受 archive-first 保護，hook 拒絕編輯，所以更正寫在這裡，不改封存檔：

- `2026-11-14-idd-484-update-calendar-identifier-follow/proposal.md` 的 Success Criteria「span `future` 的寫入不觸發改寫」：只對重複事件成立。一次性事件帶 span `future` 與 `calendar_name` 時，事件不重複，條件 2 成立，其餘條件也成立時會改寫（#554 第 5 項）。
- `2026-11-17-idd-538-fix1/proposal.md`（Proposed Solution 的 R1）與 `tasks.md` 2.1 說 part-way 的文字「以 batch 句子結尾」：實際是 batch 句子放在失敗項目自己的錯誤之前，訊息以失敗項目的錯誤結尾（G8、G13）；位置現在由 `UndoBatchRestoreTests.testThePartWayTextCarriesTheBatchSentenceBeforeTheFailedItemsError` 檢查。
- `2026-11-16-idd-538-recreated-item-records-follow/tasks.md` 4.2 在 fix1 那一輪原地改寫（`shared.` 改成 `undoHistory.`），沒有加日期註記（G12）。
- `2026-11-16-idd-538-recreated-item-records-follow/proposal.md` 的 Impact 說修改的測試檔都是「機械性加上 `id`」：`EventUpdateFollowWiringTests`（呼叫點的計數 pin 從五處改成六處）、`ManifestParityTests`（新的 pin）、`SeriesExceptionsUndoTests`（新的測試）與 `UndoBatchWiringTests`（新的 pin）不只是加 `id`（G30）。
- `2026-11-17-idd-538-fix1/tasks.md` 4.0 說 `EventUpdateFollowWiringTests` 不改內容：fix1 那一輪改了它的一段註解（F21），斷言沒有改（G30）。
- `2026-11-17-idd-538-fix1/proposal.md` 的 Impact 列了 `NewObjectSaveTests` 與 `UndoBatchRestoreTests`，那一輪沒有改它們；漏了改過的 `DeleteUndoTests` 與 `UndoBatchPartialRestoreTests`（G33）。

## Non-Goals

- 執行期的回應文字不改（#559 G6 的單筆句子、G39 的 part-way 相鄰兩句）：那些字串逐字寫在規格裡，裝置紀錄也是這些字。#555 第 2 項點名的 `leftBehind` 是例外，照該項改。
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
