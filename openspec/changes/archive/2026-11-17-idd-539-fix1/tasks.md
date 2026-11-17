## 1. 量測（Step 0）

- [x] 1.1 S1、S2 在 `3587d72e` 與 `main`（`bdcb8f9e`）的簽章 release build 上各跑 (a)(b)，四個結果送給協調者；驗證：`T/dev539/out5_*.txt` 與送出的訊息

## 2. 裁定 A：只有沒有時區的系列取牆上時間讀法

這一組到第 5 組實作 requirement「An edited occurrence's recorded slot is read both ways」的修改。

- [x] 2.1 An edited occurrence's recorded slot is read both ways（裁定 A，擷取）：擷取（`SeriesExceptionsUndo.capture(of:in:now:zone:)`）只在系列物件沒有時區時取兩種讀法；新的 store 需求 `SeriesExceptionsStoreSource.isFloating`；fake 預設有時區；驗證：S1a、S1b 在 fake 上經正式路徑先紅後綠，`UndoSlotComparisonEquivalenceTests` 新增過時 `/RID=`（差 24 小時減時差、差負時差）的有時區紀錄並與 `UndoSlotComparisonsOnMain` 相同
- [x] 2.2 origin（`OccurrenceOrigin.of`）只在刪除或搬移解析到的事件沒有時區時取牆上時間讀法，三個呼叫點（`DeletedEventSnapshots`、`recordingSeriesDelete`、split move）都明確傳入；驗證：`SlotReadingsZoneWiringTests` 釘住三處，`OccurrenceSlotGuardTests` 的有時區 origin 只有一種讀法
- [x] 2.3 #263 的兩個擷取回到 `main` 的一種讀法；驗證：wiring pin

## 3. 裁定 B、C、D、E：放置

- [x] 3.1 兩種讀法的紀錄放在 kept slot、放在視窗外、或兩筆放在同一時段時，`placeDetached` 回 nil（所有例外都不套用）；驗證：`FloatingSeriesExceptionsUndoTests` 各一個形狀（含 F2/F3 的錨點與第 i−1 場形狀、改寫的四個視窗邊界形狀）
- [x] 3.2 `endsBeforeItStarts` 對任何放好的紀錄都檢查；驗證：一種讀法、結束在開始之前的紀錄停止還原
- [x] 3.3 F24：`placementMargins` 的區間（寬度與包含 window.end 的起點）有純函式測試，另有一個兩種讀法都跨過視窗邊界的形狀

## 4. 裁定 F：#321 的檢查

- [x] 4.1 `OccurrenceSlotGuard.answer` 回三種答案：時刻讀法持有 → held；只有一般場次在牆上時間讀法 → 拒絕並保留紀錄；修改過的持有者只比時刻；持有者不再取牆上時間讀法；驗證：`OccurrenceSlotGuardTests`（含 F1、F4 的 ±12 小時跨種類形狀與 S1b 形狀）
- [x] 4.2 拒絕（`OccurrenceSlotWallClockRefusal`，`TrustedErrorMessage`，不是 `UnrecoverableUndoError`）在 `.deleteOccurrence`、rule-less `.deleteEvent` 與 split move 的 undo 都什麼都不寫、保留紀錄；split move 用搬移的說法、副本不動；batch 裡保留在剩下的紀錄；驗證：`FloatingSeriesExceptionsUndoTests` 與 `MoveByCopyUndoTests`、文字經正式的 builder

## 5. 裁定 G：刪除時的預告

- [x] 5.1 `unplacedEdits` 用和還原同一個放置判定（B、C、D），擷取到的一般場次不是展開器的場次時回 nil；驗證：`SeriesDeleteForecastTests`（含 F33：結束在開始之前的紀錄不算）

## 6. 文字（裁定 H）

- [x] 6.1 F5、F11、F12、F13、F16、F17、F19、F20、F21、F22、F23、F26、F29、F30、F32 的描述、manifest、README、CHANGELOG、規格與 gate 更正，每個 pin 唯一；F9/F18 刪掉沒有呼叫者的 `slot(placedAmong:)`；F34 的 spec example 測試補齊；驗證：`ManifestParityTests`、`SlotReadingsDocsTests`、`spectra validate`

## 7. 驗證與紀錄

- [x] 7.1 每個新分支與新文字一個 mutant，全部紅；三個時區全套測試 0 failures；對 `4668699e` 與 `origin/main` 的刪除測試檢查；驗證：mutation 表與 log
- [x] 7.2 修正後的簽章 build 上重跑 S1、S2、F1、D2、MA、B1、N1–N3、DS1、DS2、R2、L1，並跑 F 拒絕的裝置格；清除拋棄式日曆並間隔一分鐘以上數兩次；驗證：裝置紀錄
- [x] 7.3 archive 這個 change、推上去、CI 五項通過，#539 的 Verify-fix（round 1）、#539 與 #541 的新 Implementation Complete、PR 內文、兩個 issue 的 Current Status

## 紀錄（最後的 head）

- 7.1：mutant 37 個，全部紅（A1–A7、B1、C1、D1–D2、E1、F1–F8、G1–G3、M1–M2、T1–T12；表在 PR 內文）。全套測試 3,341 個，主機時區、`TZ=UTC`、
  `TZ=America/Los_Angeles` 都 0 failures。對 `4668699e`：測試函式 3,334 → 3,355，五個名稱不在了（四個改名重寫、一個隨 `slot(placedAmong:)`
  刪除）；對 `origin/main`（`bdcb8f9e`）：3,269 → 3,355，沒有刪除。
- 7.2：`6851a4b9` 的簽章 release build（之後的 commit 只改文件與測試）在 iCloud 的拋棄式日曆 `#539 W` 上跑 S1、S2、FR、F1、D2、MA、B1、
  N1–N3、DS1、DS2、R2、L1，結果見 release gate 第 1–12 步；日曆在 10:49:53（+08:00）刪除，10:49:59 與 10:51:13 各數一次，名稱含 `#539` 的都是 0。
- round 0 封存的 change（`2026-11-17-idd-539-rid-slot-readings`）的紀錄更正（verify F31、F35；封存的資料夾受 archive 保護，沒有改動）：
  它的 tasks 6.1 的 73 個 mutant 是封存時的數字，round 0 最後的 head `4668699e` 共 87 個；6.3 的「`3587d72e` 的 `Sources/` 與 head 相同」只對
  `95814269` 成立；proposal 的 Impact 少列第 6 步的檔案（`DeleteUndo.swift`、`EventKitManager.swift`、`EventKitManager+SeriesExceptions.swift`、
  `EventDeletionSource.swift`、`EventBatchDeletionSource.swift`、`UndoEventOutcome.swift`、`SeriesDeleteForecast*Tests`、
  `SeriesExceptionsTextTests`、`SlotReadingsDocsTests`）；Non-Goals 的「另開 issue」是 #557。
