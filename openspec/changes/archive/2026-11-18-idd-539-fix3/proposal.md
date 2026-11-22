## Problem

PR #558（#539）第三輪 verify 在同一個機制裡又找到一條嚴重方向的路徑（J1、J2）：沒有時區的系列，整個系列刪除的 undo 把兩種讀法的紀錄放到重建系列的時段上。

- 過時的紀錄（整個系列移動整整一個週期之後，`/RID=` 沒變）真正的時段在所有視窗之外，牆上時間讀法卻落在視窗內一個被單獨刪除的時段上，於是被放到那裡。
- 還原只在視窗內列出、只移除視窗內的時段，所以真正的時段上照規則的場次留著，一次性事件又寫在同一個開始時間：兩個事件，`stayedDeleted` 也是錯的。
- `main` 對這種系列只依規則還原，不會寫出重複的事件。

連續三輪 verify（round 1 的 F2、F3，round 2 的 H1、H4、H5，round 3 的 J1、J2）每一輪都在這個放置裡找到一條新的嚴重路徑，協調者的門檻（再一條嚴重路徑）已經達到。

## Root Cause

兩種讀法的紀錄只能靠「恰好一種讀法是重建系列的時段」決定它屬於哪個時段；紀錄過時（系列在修改之後被移動）時，這個判斷可能選錯，而且錯在擷取看得到的範圍邊緣時，還原沒有辦法發現。每一輪加上的條件（B、C、D、I）都只擋住一種形狀。

## Proposed Solution

依協調者在維護者「把事情做完」的指示下做的決定：**這個 PR 撤回沒有時區的系列的放置**，#539 保持 open 給這部分。

- 整個系列刪除的擷取裡只要有一筆兩種讀法的紀錄（讀取時沒有時區的系列、主機時差不是 0 時修改過的場次），還原就不套用任何例外，系列照規則回來；undo 的文字說出原因：沒有時區的系列裡單獨修改過的場次，原本的時段無法可靠地讀出。這是 `main` 對這些形狀的結果，只是把原因說清楚，不再說「did not match」。
- 刪除時的預告：擷取有兩種讀法的紀錄時，每一筆修改都算進去，`undo_note`／`rules_alone_on_undo` 說同一個原因；只有一種讀法的紀錄維持原本的預告（記錄的時段不是規則從第一個時段展開的時段），不給說明的情形不變。
- 移除只為放置兩種讀法的紀錄而存在的程式：裁定 B、C、D、I（`placement`、`placeDetached`、`firstSlotStopsTheRestore`）、14 小時的邊距列出（`placementMargins`、`needsMargins`、`SlotReadings.largestOffset`、`SlotReadings.place(among:)`）、擷取上的 stand-in 紀錄（`throughStandIn`、`captureSeriesExceptions(of:viaStandIn:)`）。
- 保留：裁定 A（有時區的系列只有一種讀法，走 `main` 的路徑）、擷取時任一種讀法在視窗內就記錄（停止還原靠它看到紀錄）、裁定 E（結束在開始之前的紀錄停止還原，現在只到得了一種讀法的紀錄）、裁定 F（#321 的時段檢查）、裁定 J（origin 讀系列的時區）、#541 的文字、與 #538 的互動（不套用的還原讓較舊的紀錄跟著走）。

## Non-Goals

- 還原沒有時區的系列的修改：#539 保持 open。
- `main` 本身的缺陷：#560（有時區的系列移動整整一個週期之後遺失場次）、#561（stand-in 刪除留下 stand-in 與修改過的場次，undo 在那裡多一個事件）。
- 第三輪 verify 中撤回之後不再成立、或不是文字的 LOW 與 INFO：列在報告的後續 issue 清單。

## Success Criteria

- 矩陣（`FloatingSeriesUndoMatrixTests`）加上 J1 的兩種形狀（真正的時段在視窗結束之後、在視窗開始之前），在 `c569fe68` 上紅；撤回之後每一格兩種讀法的格子都是照規則重建的行事曆、計數為 0、沒有兩個事件同一個開始時間、文字說出原因；一種讀法的格子與 `main` 相同。
- mutant：重新啟用兩種讀法紀錄的放置、拿掉預告的新條件、拿掉原因的文字，各自讓測試變紅。
- 裝置格 F1、D2、MA、FR、S1、S2、N1、DS1、SD、FW 與 #538 的 sequence 1、8 在新的簽章 build 上照 gate 所寫。

## Impact

- Affected specs: `undo-history-discard`（修改 requirement「An edited occurrence's recorded slot is read both ways」）
- Affected code:
  - Modified: `Sources/CheICalMCP/EventKit/SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`, `Sources/CheICalMCP/EventKit/SlotReadings.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesUpdateUndo.swift`, `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/EventBatchDeletionSource.swift`, `Sources/CheICalMCP/EventDeletionSource.swift`, `Sources/CheICalMCP/EventKit/DeleteUndo.swift`, `Sources/CheICalMCP/EventKit/UndoEventOutcome.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`
  - Removed tests: `Tests/CheICalMCPTests/SeriesPlacementTests.swift`, `Tests/CheICalMCPTests/SeriesFirstSlotStopTests.swift`
  - New tests: `Tests/CheICalMCPTests/FloatingSeriesRulesAloneTests.swift`
  - Changed tests: the matrix and the tests of the removed rulings (listed in the PR body with their reasons)
