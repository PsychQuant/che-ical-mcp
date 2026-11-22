## 1. 矩陣（先紅）

這一組到第 3 組實作 requirement「An edited occurrence's recorded slot is read both ways」的修改。

- [x] 1.1 An edited occurrence's recorded slot is read both ways（矩陣）：`FloatingSeriesUndoMatrixTests`，7,812 格（六個固定時差主機、每日與每週、06:00 與 22:00、哪一場修改、移動 0／±1／±2 個週期／一天減時差／負時差／正時差／3 小時、哪幾場單獨刪除、系列物件與 iCloud stand-in 兩條路線、stand-in 刪除留下什麼的兩種模型），經正式的擷取、`FirstRemainingOccurrence.resolve`／`pick`／`earliestEdited` 與 undo 臂；驗證：`adfc902e` 上兩種讀法的格子 166 格紅，H1、H4、SA 三個具名格紅；全部不套用的對照（暫時讓 `placeDetached` 一律回 nil）只有必須套用的 360 格紅

## 2. 裁定 I

- [x] 2.1 An edited occurrence's recorded slot is read both ways（裁定 I）：`SeriesExceptionsPlanner.firstSlotStopsTheRestore`（有兩種讀法的紀錄時，(a) `throughStandIn` 或 (b) 第一個時段在視窗內且不是 kept slot），還原在放置之前問，`Outcome.firstSlotNotPlain` 與自己的文字（單一與 batch）；驗證：只加 (b) 時矩陣 80 格紅（都在 stand-in 路線），加 (a)+(b) 全綠，走 KEEP；`SeriesFirstSlotStopTests`
- [x] 2.2 擷取記下解析帶的 `viaStandIn`（`captureSeriesExceptions(of:viaStandIn:)`，五個呼叫點與 #263 的擷取都明確傳入）；驗證：`DeleteUndoTests`、`SeriesDeleteForecastWiringTests` 的 pin
- [x] 2.3 刪除時的預告在 `.stored` 的檢查之前問同一個函式，成立時把每一筆修改都算進去，說明的原因列表加上這一項；驗證：`SeriesFirstSlotStopTests`、`SeriesDeleteForecastTests`、wiring pin

## 3. 裁定 J

- [x] 3.1 origin 讀系列的時區（`OccurrenceOrigin.seriesIsFloating`、`EventKitManager.seriesIsFloating(of:)`），三個 origin 的產生點（`DeletedEventSnapshots`、`recordingSeriesDelete`、split move）都經由它；驗證：`OccurrenceOriginTests.testAnOriginIsTakenWithItsSeriesZone`、`SlotReadingsZoneWiringTests`
- [x] 3.2 H27：裁定 D 只把兩種讀法的紀錄算成原因；驗證：`SeriesPlacementTests.testARecordOfOneReadingIsNeverTheReason`、`testTwoRecordsOnOneSlotAreNotPlaced`

## 4. 裁定 K 的測試與文字

- [x] 4.1 H6、H8、H32：batch 對 slot 檢查拒絕的成員說它什麼都沒寫；驗證：`OccurrenceSlotWallClockRefusalTests.testInABatchTheRefusedMemberIsKept`
- [x] 4.2 H16、H23：split move 的拒絕說「the moved occurrence's original slot」，兩種拒絕都說放棄會留下什麼；H19：store 層以 `.undoMoveByCopy` 呼叫；驗證：`FloatingSeriesExceptionsUndoTests`
- [x] 4.3 H17：放不上去、結束在開始之前的紀錄給放置的答案；H30：放上去的浮動紀錄讓 #538 標記較舊的紀錄；H3：`main` 遺失場次的那一格分開計數（#560）；驗證：各自的測試
- [x] 4.4 H18、H25、H35 的註解；描述、manifest、README、CHANGELOG、spec、gate（H9、H10、H11、H12、H15、H33、H34，trace 區塊 H7）
- [x] 4.5 PR body（H2、H21、H45）與 Implementation Complete 的紀錄（H13、H14、H20、H31、H36）

## 5. 證明

- [x] 5.1 mutant：拿掉 (a)、拿掉 (b)、拿掉視窗內的條件、套用到一種讀法的紀錄，各自讓矩陣紅；另有裁定 I、J、K 的其他分支與文字（表在 PR 內文）
- [x] 5.2 三個時區完整測試、0 失敗；對 `adfc902e` 與 `origin/main` 以（檔案、名稱）檢查沒有移除的測試
- [x] 5.3 iCloud 裝置格（新的簽章 build）：S1、S2、FR、FW、F1、D2、MA、N1、DS1、SD 與 #538 的 sequence 1、8
