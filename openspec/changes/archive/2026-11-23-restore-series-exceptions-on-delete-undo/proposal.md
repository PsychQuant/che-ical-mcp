## Problem

刪除整個重複系列後再 `undo`，系列是從「規則」重建的，重建出來的內容與刪除前不一致（#285）：

1. **早先單獨刪除的場次會回來。** 系列中某一場先用 span "this" 刪掉，之後整個系列被刪（`delete_event` span "future" 從第一場起，或 span "all"），`undo` 後那一場又出現。接著再 `undo` 先前那次「單一場次刪除」，同一時段會有兩個事件（系列的場次加上一次性事件）。
2. **單獨編輯過的場次會丟掉編輯。** 被單獨編輯的場次（detached occurrence）在整個系列刪除時一起被移除，`undo` 只把該時段還原成系列的普通場次，編輯不見。

## Root Cause

整個系列刪除記錄的是「系列物件」的快照（`EventSnapshot(from:)`），裡面只有該事件的欄位與 `recurrenceRules`，**沒有任何場次層級的狀態**。`undo` 的 `.deleteEvent` 分支建立新事件、套用快照、`save`，由 EventKit 依規則展開出每一個時段，所以規則會生成的每個時段都回來。`.deleteOccurrence` 分支則無條件在該時段寫入一次性事件，不檢查時段是否已被重建的系列佔用。

EventKit 的公開標頭沒有例外日期或已刪場次的 API（只有唯讀的 `isDetached`、`occurrenceDate`）。但實機驗證（2026-10-12，iCloud，拋棄式日曆）顯示：刪除前可以列舉系列實際存在的場次，與規則展開的結果做差集，就得到例外，不必自己實作重複規則展開（見診斷留言）。

三個記錄點共用 `EventSnapshot(from:)`：`deleteEvent`（整個系列的分支）、`deleteEventSeries`、`deleteEventSeriesBatch`。

## Proposed Solution

維護者已決定（A）還原例外，並在重複時不寫入並說明：

- **刪除前記錄例外**：在系列快照上加一個值型別 `SeriesExceptions`，在移除之前，於掃描視窗內（沿用 #259 的 `seriesScanWindow`）列舉實際存在的場次：記下「刪除前存在的時段集合」，以及每個 detached 場次（以去掉規則的一次性快照記錄，原始時段取自識別碼的 `/RID=`，即 #311 的 `originalSlot`）。三個記錄點共用同一個擷取函式。
- **undo 時還原**：照舊從規則重建系列；然後列舉 EventKit 重建後實際產生的時段，凡是不在「刪除前存在的時段集合」內的，就用既有的 `ExclusionExecutor`（兩段式：先解析全部、再移除，失敗時補償刪除整個系列）排除；detached 場次以一次性事件重建（EventKit 無法把編輯過的場次放回系列，沿用 #244 的 D1 先例）。
- **重複防護**：`.deleteOccurrence` 的 undo 在寫入前檢查該時段是否已被系列場次佔用；已佔用就不寫入，訊息說明「該場次已由系列還原」。
- **揭露**：重寫 `seriesRulesRestoreNote`、`seriesRulesListingNote` 與 tool 描述，如實說明「視窗內的例外會還原；視窗外、或刪除之後才由別處產生的例外看不到」，並刪除「span 'all' 尚未檢查」的字樣（已於本次診斷驗證）。

## Non-Goals

- **不處理 #279**（以日期範圍加 span future 的批次刪除把後續場次回報為失敗）與 **#284**（第一場被刪後系列物件無法 refresh）。兩者是各自獨立的問題。
- **不嘗試把編輯過的場次放回系列**：EventKit 沒有此能力；以一次性事件還原。
- **不做 B（拒絕並丟棄）與 C（只防重複）**：維護者已選 A；兩者留在 design 的「備選方案」中說明為何不採用。
- **不在儲存層修正例外**：不自己實作重複規則展開，例外一律由「列舉實際場次」與「EventKit 展開結果」的差集得到。

## Success Criteria

在 iCloud 實機與單元／handler 測試中，下列皆成立（案例編號同診斷留言）：

- 案例 1：週重複 ×3，先刪第 2 場，再整個系列刪除（span future 從第 1 場），`undo` 後只有第 1、3 場（第 2 場維持刪除）；再 `undo` 先前的單一場次刪除，第 2 場以一次性事件還原，同一時段只有一個事件（實機 2026-10-12：三場齊全）。**更正**：本 change 最初寫成「第二次 undo 不寫入」是錯的，時段在系列 undo 後是空的，寫入才對；重複防護只在時段已被系列佔用時觸發（視窗外的場次、或無法列出例外的記錄），實機以視窗外場次驗證：不寫入、訊息說明、無重複。
- 案例 2：第 2 場被單獨編輯，整個系列刪除後 `undo`：系列的第 1、3 場在，第 2 場以帶編輯（標題）的一次性事件還原，訊息說明它已不屬於系列。
- 案例 3：同上但用 span "all"，並含一個刪除的中間場次與一個編輯過的場次，行為與案例 1、2 一致。
- 案例 4：只刪**最後**一場再刪整個系列，`undo` 不多排除任何時段。已驗證（iCloud）：刪最後一場會把規則 `count` 從 4 縮成 3，刪中間一場則不改規則，所以快照本來就帶著尾端的刪除，差集不需要特別處理。
- 部分失敗：排除或重建 detached 場次中途失敗，留下的狀態不是「被排除一半的系列」；失敗時補償刪除重建出的系列，並回報。
- 掃描視窗外：開放式或很長的系列，視窗外的例外看不到，訊息與 tool 描述明說這個限制。
- 在 Google 日曆上，上述案例與 DST／非台北時區各至少跑一次（尚未驗證，列為驗證項目而非已知成立）。

## Impact

- Affected specs: `undo-history-discard`（修改「Delete of a whole series (#244)」、「Delete of one occurrence (#244)」，新增例外還原、detached 場次還原、視窗限制、重複防護的場景）；`recurrence-excluded-dates`（只檢查一致性，預期不需修改）。
- Affected code: `Sources/CheICalMCP/EventKit/UndoManager.swift`（`EventSnapshot`、`UndoOperation`）、`DeleteUndo.swift`（`DeletedEventSnapshots`、還原訊息與揭露）、`EventKitManager.swift`（`deleteEvent`、`deleteEventSeries`、`deleteEventSeriesBatch`、`executeUndo` 的 `.deleteEvent` 與 `.deleteOccurrence` 分支、批次還原）、`UndoPostStateGuard.swift`（重用 `seriesScanWindow`、`originalSlot`）、`ExclusionExecutor.swift`（重用）、`Server.swift`（`undo`、`delete_event`、`delete_events_batch` 的描述）、兩份 README、plugin README、兩份 CHANGELOG、`Tests/CheICalMCPTests`。
