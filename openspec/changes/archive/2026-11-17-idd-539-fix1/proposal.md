## Problem

PR #558（#539）第一輪 verify 找到一個相對於 `main` 的退步，2026-11-17 在 iCloud（主機 `+08:00`）用 `3587d72e` 與 `main`（`bdcb8f9e`）的簽章 build 量到（cell S1、S2）：

- 有時區的每日系列，第 2 場改標題後整個系列同一天延後 16 小時。改過的場次跟著移動，`/RID=` 留在舊時段。這個 `/RID=` 的牆上時間讀法正好是新系列的第一個場次。
- 整個系列刪除後 undo：PR 把這筆紀錄放在錨點上，第 2 場被當成多餘的場次移除，也沒有寫一次性事件，只剩 5 場，回應卻說「1 個單獨刪除的場次維持刪除」。`main` 照規則重建 6 場。
- 用該場次自己的 id 刪除後 undo：#321 的檢查以牆上時間讀法判定「系列已持有這個時段」，什麼都沒寫，紀錄也離開 undo 堆疊。`main` 寫回一次性事件。
- 先 `clear_timezone` 再刪除（S2）時，`clear_timezone` 被 #503 的檢查拒絕，結果同 S1。

## Root Cause

PR 給每一個計時 `/RID=` 兩種讀法，有時區的系列也一樣。整串改時間後，`/RID=` 留在舊時段（N1 量到），錯的那一種讀法可能落在系列的場次上，而真正的時段兩種讀法都不是。放置（`placeDetached`）只看「恰好一種讀法是場次」，不看那個場次在擷取時是不是一般場次；#321 的檢查（`isHeld`）把兩邊的所有讀法互相比對，錯的讀法也能讓它回答 held。

## Proposed Solution

依協調者的裁定 A–G：

- **A**：只有讀取時系列沒有時區的場次才取牆上時間讀法：刪除的擷取看系列物件，場次的 origin 看刪除時解析到的事件（從系列 id 進來是系列物件，從場次自己的 id 進來是那個場次），持有者不取。有時區的系列只有時刻一種讀法，每一條路徑都是 `main` 的。#263 的兩個擷取也回到 `main`。
- **B**：兩種讀法的紀錄不放在擷取時有一般場次的時段（kept slot）上；放上去了就算放不上去，所有例外都不套用。
- **C**：兩種讀法的紀錄放在所有視窗之外（14 小時的邊界裡）時，所有例外都不套用（不再丟掉這筆、套用其餘）。
- **D**：兩筆紀錄放在同一個時段時，所有例外都不套用。
- **E**：放好的紀錄只要結束在開始之前，不論有幾種讀法，就停止還原（夏令時間的情形）。
- **F**：#321 的檢查改成三種答案：系列（或 undo 從它重建的系列）的場次以時刻讀法持有 → 照 `main` 回答 held；只有一般場次在 origin 的牆上時間讀法上 → 什麼都不寫、拒絕 undo、保留紀錄，訊息說明並指向 `discard_id`；其餘 → 寫回一次性事件。修改過的持有者只比時刻。拒絕在 split move 的 undo 裡用搬移的說法，副本不動。
- **G**：刪除時的預告用和還原同一個放置判定（含 B、C、D）；擷取到的一般場次有任何一個不是展開器的場次時，不給預告（#503 檢查自己的防護）。
- 文字（裁定 H）、規格、release gate 一併更正。

## Non-Goals

- 另一種讀法的持有者（例如重建的浮動系列又被單獨改過、在同一個真正時段上）：照 `main` 的比對，會寫第二個事件，列入後續 issue。
- 刪除前又讀到時區的系列（#541 在 Google 上看到）：照 `main` 處理，寫成限制。
- 試跑的擷取在同一次呼叫較早的列之前執行（F10）、span `all` 的試跑每一列都擷取（F15）、F27、F28：由協調者在 close 時開 issue。
- #503、#416、#509 與 create-undo 檢查怎麼讀浮動系列的 `/RID=`（#553、#557）。

## Success Criteria

- 擷取時有時區的系列，經由正式路徑（記憶體內 store 與 `UndoSlotComparisonsOnMain` 的對照）結果與 `main` 相同，包含 `/RID=` 過時、差 24 小時減時差與差負時差的紀錄。
- S1、S2 在修正後的簽章 build 上：沒有場次遺失、沒有重複、沒有紀錄無聲消失，每個回應說明發生了什麼。
- F1、D2、MA、B1、N1–N3、DS1、DS2、R2、L1 在修正後的 build 上回應與先前相同。

## Impact

- Affected specs: `undo-history-discard`（修改 requirement「An edited occurrence's recorded slot is read both ways」）
- Affected code:
  - Modified: `Sources/CheICalMCP/EventKit/SlotReadings.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptionsStoreSource.swift`, `Sources/CheICalMCP/EventKit/DeleteUndo.swift`, `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`
  - Tests: `Tests/CheICalMCPTests/Helpers/FakeSeriesExceptionsStore.swift`, `Tests/CheICalMCPTests/FloatingSeriesExceptionsUndoTests.swift`, `Tests/CheICalMCPTests/OccurrenceSlotGuardTests.swift`, `Tests/CheICalMCPTests/SlotReadingsTests.swift`, `Tests/CheICalMCPTests/SeriesDeleteForecastTests.swift`, `Tests/CheICalMCPTests/UndoSlotComparisonEquivalenceTests.swift`, `Tests/CheICalMCPTests/SeriesExceptionsTests.swift`, `Tests/CheICalMCPTests/ManifestParityTests.swift`, `Tests/CheICalMCPTests/SlotReadingsDocsTests.swift`, and new `Tests/CheICalMCPTests/SlotReadingsZoneWiringTests.swift`
