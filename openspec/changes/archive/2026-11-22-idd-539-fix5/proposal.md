## Problem

PR #558（#539）第五輪 verify 從程式讀出：第四輪保留的裁定 F（#321 的時段檢查在只有牆上時間讀法那裡有一個沒單獨修改的場次時拒絕）不是「永遠不比 `main` 差」。

- P1、P3、Q3（MEDIUM）：F 拒絕了 `main` 做對的還原。系列有時區時修改的場次（時刻型的 `/RID=`），之後系列變成沒有時區並移動，讓一個一般場次剛好落在牆上時間讀法上；或一個沒有時區的系列的場次修改並移動之後，它存下的開始時間是空的。`main` 寫回一次性事件，是對的；F 拒絕、紀錄保留、每次重試都拒絕，只能用 `discard_id` 放棄，修改就沒了。
- Q1（HIGH）：拒絕經由批次的中斷路徑，批次的 undo 停在 `main` 會還原的其他無關成員之前。
- Q6（MEDIUM）：裁定 J 讀 `storedEvent(id:)` 為 `/RID=` 前那段回傳的東西的時區，沒有確認它是系列物件。
- Q2（MEDIUM）：dry run 的預告在擷取之後用從識別碼讀出的時段切掉較早的列刪掉的場次：`/RID=` 只在 external identifier 的不透明 id 不會被切掉；兩個不同的場次記在同一個時段時兩個都被切掉。

## Root Cause

F 用「同一串數字的牆上時間讀法上有一般場次」推定「這個時段可能已被佔用」。這個推定只在數字是牆上時間時成立；時刻型的 `/RID=`、移動過的修改，牆上時間讀法上的一般場次是另一個場次，`main` 的還原是對的。拒絕又沿用批次的中斷路徑。第四輪的規則是「只保留永遠不比 `main` 差的部分」，F 不符合這條規則。dry run 的切割在擷取把場次化成時段之後才做，所以只能以時段比對。

## Proposed Solution

照第四輪的規則：

- 移除裁定 F 與裁定 J（含 C5）以及只為它們存在的程式：`SlotReadings`、`OccurrenceOrigin.wallClock`、`SeriesHolder.edited`、`OccurrenceSlotGuard.Answer` 與 `answer`、`OccurrenceSlotWallClockRefusal` 與它的文字、`slotCheck`、`seriesIsFloating`、`isFloating`、批次的 `refusedAtItsSlot`。#321 的時段檢查、單一場次與 split move 的 undo 回到 `main`（92d9b796）的程式。
- 保留 #541 的描述修正。
- 保留刪除時的預告（`undo_note`、`rules_alone_on_undo`，實際呼叫與 dry run），它預測 `main` 的還原。Q2：dry run 改在擷取之前，以識別碼排除較早的列刪掉的場次（`DryRunCaptureStore`，列出時以場次自己的 event identifier 比對）；擷取本身仍是 `main` 的。Q9、Q11：說明只說一致性檢查能確定的事（預期不套用任何記錄的例外），上限是展開範圍內的場次數。
- 測試：矩陣與鏈測試保留，作為與 `main` 相同的證據；Q4：`main` 的一邊改用 92d9b796 的 restore；Q5、P14、P20：說清楚矩陣顯示的範圍；P4：鏈測試也比對兩次 undo 的文字，並加上 MA 的鏈。
- 前幾輪封存的提案（`idd-539-rid-slot-readings`、`fix1` 到 `fix4`）描述的兩種讀法的擷取、放置、裁定 B 到 J 都已不在程式裡；以這個提案為準（P10）。第四輪封存提案引用的 40／6 是不同基準的舊數字。第五輪矩陣斷言 2,832 格未通過矩陣檢查，其中 326 格有兩個事件同時開始。浮動 RID、非零時差且還原曾套用記錄的那一組為 230／6（P2、P16）。

## Non-Goals

- #539：還原沒有時區的系列的修改，保持 open。`main` 自己的重複（MA 的鏈）也記在那裡。
- `main` 本身的缺陷 #560、#561。

## Success Criteria

- Q2 的兩個形狀（不透明 id、同一時段的兩個場次）在 `8e642f4e` 的切割上紅，改完綠。
- 移除後，#321 的時段檢查、`OccurrenceOrigin`、單一場次與 split move 的 undo、批次 undo 的程式與 `main` 相同；`main` 的測試全部保留。
- 矩陣、C1 的兩條鏈與 MA 的鏈與 `main` 相同（答案、文字、行事曆）。
- mutant：拿掉預告的條件、拿掉或改回時段式的 dry run 切割（Q2 的形狀紅）、每一段新文字。
- 三個時區完整測試、0 失敗。iCloud 裝置格只量預告：`delete_event`（span all、span future）與 `delete_events_batch`（dry run 與實際呼叫）。

## Impact

- Affected specs: `undo-history-discard`（requirement 改名為「An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo」並改寫）
- Affected code:
  - Reverted to `main`: `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`, `Sources/CheICalMCP/EventKit/UndoBatchRestore.swift`, `OccurrenceOrigin` and `OccurrenceSlotGuard` in `Sources/CheICalMCP/EventKit/SeriesExceptions.swift`, the origin and snapshots in `Sources/CheICalMCP/EventKit/DeleteUndo.swift`
  - Removed: `Sources/CheICalMCP/EventKit/SlotReadings.swift`
  - New: `Sources/CheICalMCP/EventKit/DryRunCaptureStore.swift`
  - Modified: `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/EventBatchDeletionSource.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`
  - Tests: the tests of the removed parts (listed in the PR body with their reasons), the forecast tests, the chain and matrix tests, the main-copy helper
