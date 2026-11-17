## Problem

PR #558（#539）第二輪 verify 在還原的放置裡找到一條嚴重方向的路徑（H1、H4、H5），只在沒有時區的系列上：

- 整個系列在別的 client 移動整整一個週期之後，修改過的場次 `/RID=` 過時；它錯的那一種讀法可能落在擷取時沒有一般場次的時段上而被放上去。
- 還原時重建系列的第一個時段是錨點：從不移除、也不寫一次性事件。所以紀錄放在錨點上時那個場次遺失（H1），或第一個場次本身被修改、紀錄放到別的時段時同一個時間有兩個事件（H4）。
- iCloud 上第一個場次被單獨刪除或修改時，刪除經由 stand-in（#326）找到系列，重建的系列從 stand-in 開始；stand-in 被接受、紀錄放在單獨刪除的時段上時也會多一個事件（矩陣測試中 40 格，裝置格 SA）。

另外：自己 id 的刪除與 split move 的 origin 讀的是場次本身的時區（H22）；裁定 D 把只有一種讀法的紀錄也當成不套用的原因（H27）；以及第二輪的文字、紀錄與測試（裁定 K）。

## Root Cause

放置只看紀錄的兩種讀法與擷取時的一般場次，不看重建系列的第一個時段。第一個時段在擷取時不是一般場次時，或刪除經由 stand-in 時，錨點與紀錄的關係在擷取裡看不出來，過時的 `/RID=` 就可能被放到錯的時段。

## Proposed Solution

依協調者的決定（裁定 I、J、K）：

- **裁定 I**：至少有一筆兩種讀法的紀錄時，(a) 刪除經由 stand-in 找到系列（解析本身帶的 `viaStandIn`，記在擷取上），或 (b) 重建系列的第一個時段在視窗內、擷取時不是一般場次，就什麼都不套用；系列照規則回來，undo 的文字自己說明原因。同一個函式（`SeriesExceptionsPlanner.firstSlotStopsTheRestore`）給還原與刪除時的預告用；預告在這時把每一筆記到的修改都算進去。
- **矩陣決定分支**：`FloatingSeriesUndoMatrixTests`（7,812 格）在 `adfc902e` 上兩種讀法的格子有 166 格紅；只加 (b) 時 80 格紅（全部在 stand-in 路線）；加 (a)+(b) 後全綠，所以走 KEEP。
- **裁定 J**：自己 id 的刪除與 split move 的 origin 讀系列的時區（經由 `/RID=` 之前的系列 id 讀系列物件），讀不到就只取一種讀法；只有一種讀法的紀錄從來不是 B、C、D、I 不套用的原因。
- **裁定 K**：batch 對拒絕的成員說它什麼都沒寫；split move 的拒絕用搬移的說法；拒絕說明放棄會失去什麼；過時的註解與文件；gate、CHANGELOG、spec 的更正；測試 H17、H19、H30、H38 與 H3 的測試註解（`main` 遺失場次的那一格分開計數，指向 #560）。

## Non-Goals

- 有時區的系列移動整整一個週期之後在 `main` 上遺失場次（#560）：這個 PR 保留 `main` 的路徑。
- 後續 issue（close 時開）：H24、H29、H43、round 1 的 F10、F15、F27、F28、Google 上又讀到時區的限制、另一種 `/RID=` 的修改過持有者。
- stand-in 刪除留下修改過的場次與 stand-in 本身（裝置格 SA 在 `main` 上也看到）：協調者另開 issue。

## Success Criteria

- 矩陣每一格：undo 之後的事件集合等於刪除前或照規則重建的集合，沒有兩個事件同一個開始時間，套用時計數為真；一種讀法的格子與 `main` 相同；必須套用的格子（沒有移動、第一個場次一般）套用。
- 四個 mutant（拿掉 (a)、拿掉 (b)、拿掉視窗內的條件、套用到一種讀法的紀錄）各自讓矩陣變紅。
- 裝置格 S1、S2、FR、FW、F1、D2、MA、N1、DS1、SD 與 #538 的 sequence 1、8 在新的簽章 build 上如 gate 所寫。

## Impact

- Affected specs: `undo-history-discard`（修改 requirement「An edited occurrence's recorded slot is read both ways」）
- Affected code:
  - Modified: `Sources/CheICalMCP/EventKit/SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesUpdateUndo.swift`, `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/EventBatchDeletionSource.swift`, `Sources/CheICalMCP/EventKit/DeleteUndo.swift`, `Sources/CheICalMCP/EventKit/UndoEventOutcome.swift`, `Sources/CheICalMCP/EventKit/UndoBatchRestore.swift`, `Sources/CheICalMCP/EventKit/SlotReadings.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`
  - New tests: `Tests/CheICalMCPTests/FloatingSeriesUndoMatrixTests.swift`, `Tests/CheICalMCPTests/SeriesFirstSlotStopTests.swift`
  - Changed tests: `DeleteUndoTests`, `DetachedOccurrenceSpanTests`, `FloatingSeriesExceptionsUndoTests`, `ManifestParityTests`, `OccurrenceOriginTests`, `OccurrenceOriginWiringTests`, `OccurrenceSlotWallClockRefusalTests`, `RulesAloneRestoreFollowHandlerTests`, `SeriesDeleteForecastTests`, `SeriesDeleteForecastWiringTests`, `SeriesExceptionsUndoHandlerTests`, `SeriesPlacementTests`, `SlotReadingsZoneWiringTests`, `ZonedSeriesUndoOnMainTests`
