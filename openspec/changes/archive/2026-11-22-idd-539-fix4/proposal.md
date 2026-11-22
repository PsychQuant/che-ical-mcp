## Problem

PR #558（#539）第四輪 verify 從程式讀出：撤回放置之後的整個系列刪除的 undo，仍在一些形狀比 `main` 差。

- C1（HIGH，嚴重方向）：照規則還原會把一個單獨刪除的場次的時段重建回來。那個場次自己的刪除紀錄之後的 undo，有時找到時段「已被佔用」而用掉紀錄、沒寫回它的修改；`/RID=` 過時時兩種讀法都不是任何時段，於是在重建的場次旁邊寫出一次性事件：同一時間兩個事件。`main` 套用另一筆紀錄、讓那個時段維持刪除，那個場次的 undo 只寫一次。
- L1、L3（MEDIUM）：只要刪除當下系列沒有時區，每一個有時間的 `/RID=` 都讓還原停下，包括系列還有時區時寫下、讀作時刻就對的 `/RID=`（裝置格 R2 的形狀）。`main` 套用這筆紀錄、修改回來。
- C2（MEDIUM）：裁定 E（結束在開始之前的紀錄停止還原）在 `main` 會保留規則的第一個場次、照樣套用較晚紀錄的地方，什麼都不套用。

四輪 verify 每一輪都找到這個 PR 的整個系列刪除的 undo 在某處比 `main` 差。

另外，封存的 `idd-539-fix3` 提案（L2）說 `main` 對這種系列只依規則還原、不會寫出重複的事件，以及照規則重建「是 `main` 對這些形狀的結果」。矩陣推翻了這兩句：`main` 在一部分形狀套用紀錄、保留修改，其中也有它自己留下兩個事件的格子。這兩句是那一輪的前提，不成立；這個提案取代它。

## Root Cause

這個 PR 把整個系列刪除的擷取與還原改成自己的版本（兩種讀法的擷取、遇到兩種讀法的紀錄就停、裁定 E 的停止）。每一輪修掉一種形狀，下一輪又在別的形狀找到比 `main` 差的結果。比 `main` 差的不是某一個條件，而是「換掉 `main` 的還原」這件事本身：凡是 `main` 會套用的紀錄，停下來就會讓 `main` 維持刪除的時段回來、讓 `main` 寫回的修改消失，而較舊的單一場次紀錄是照 `main` 的還原結果設計的。

## Proposed Solution

依協調者在維護者「把事情做完」的指示下做的決定（第四輪時告知維護者的選項）：**整個系列刪除的 undo 完全照 `main`（92d9b796），每一種系列都一樣，有沒有時區都一樣。**

- 擷取與還原回到 `main`：被單獨修改的場次的時段只讀作時刻；一致性檢查、移除多餘的時段、一次性事件與計數都是 `main` 的。移除兩種讀法的擷取、`holdsAFloatingEdit`、`Outcome.floatingEdit` 與它的文字、裁定 E 的停止（`endsBeforeItStarts`、`Outcome.endsBeforeStart` 與它的文字）、`SeriesExceptionsStoreSource.isFloating`，以及只為它們存在的程式。
- 只保留永遠不會比 `main` 差的部分：
  - #541 的描述修正（`clear_timezone` 讓事件沒有時區，不是回到系統時區）。
  - 裁定 F：#321 的時段檢查只在 `main` 也會回答「已佔用」的地方回答已佔用；只有牆上時間讀法那裡有一個沒單獨修改的場次時拒絕，什麼都不寫、紀錄保留。它寫的永遠是 `main` 會寫的子集。
  - 裁定 J：F 的讀法的來源，origin 讀系列的時區；讀不到系列時只有一種讀法。C5：`/RID=` 只在 external identifier 裡的 origin 走這個一種讀法的退路，不讀場次自己的時區。
  - 刪除時的預告（`undo_note`、`rules_alone_on_undo`），只在它預測 `main` 的還原時：記錄的時段（時刻讀法）有不是規則時段的，`main` 的一致性檢查就不套用任何例外。拿掉兩種讀法的分支與它的原因。C3：`delete_events_batch` 的 dry run 把同一次呼叫裡較早的列刪掉的場次從擷取與第一個時段的列出中排除，跟實際呼叫一致。
- #539 保持 open，給還原沒有時區的系列的修改；`main` 的 6 個重複格與 40 個被拒絕的格子記在 #539，是 `main` 自己的。

## Non-Goals

- 還原沒有時區的系列的修改：#539 保持 open。
- `main` 本身的缺陷：#560、#561，矩陣裡 `main` 自己被拒絕的格子（記在 #539）。
- 第四輪的 LOW 與 INFO 在撤回之後不再成立的：列在報告裡。

## Success Criteria

- C1 的兩個序列（整個系列的 undo，再 undo 較舊的單一場次紀錄）對 `main` 同一序列的執行斷言，在 `eb568983` 上紅，改完綠。
- 矩陣（`FloatingSeriesUndoMatrixTests`）每一格的還原與 `main` 的還原相同（undo 之後同一個行事曆、答案裡同樣的計數），`main` 的一邊用 `main` 自己的擷取；L4 修好；加上系列有時區時修改、之後 `clear_timezone`、沒有移動的形狀（L1、L3）。
- 預告在矩陣的每一格與 C3 的 dry run 形狀都跟還原一致。
- 裁定 F：`held`、`heldAtWallClockOnly`、`free` 各一個測試，寫的東西是 `main` 的子集。
- mutant：重新啟用這個 PR 的停止（矩陣對 `main` 紅）、拿掉 F（它的測試紅）、拿掉預告的條件。
- 裝置格 F1、D2、R2、MA、FR、S1、S2、N1 與 #538 的 sequence 1、8：除了 F 拒絕的地方，都是 `main` 的答案。

## Impact

- Affected specs: `undo-history-discard`（修改 requirement「An edited occurrence's recorded slot is read both ways」）
- Affected code:
  - Reverted to `main`: `Sources/CheICalMCP/EventKit/SeriesExceptionsStoreSource.swift`, `Sources/CheICalMCP/EventKit/UndoEventOutcome.swift`, and the capture and restore in `Sources/CheICalMCP/EventKit/SeriesExceptions.swift` and `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`
  - Modified: `Sources/CheICalMCP/EventKit/SlotReadings.swift`, `Sources/CheICalMCP/EventKit/DeleteUndo.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift`, `Sources/CheICalMCP/EventKit/UndoBatchRestore.swift`, `Sources/CheICalMCP/EventBatchDeletionSource.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`
  - Tests: the matrix, the main-sequence helpers, the tests of the removed parts (listed in the PR body with their reasons)
