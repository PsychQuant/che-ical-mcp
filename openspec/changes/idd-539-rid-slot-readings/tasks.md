## 1. 兩種讀法（純值）

- [x] 1.1 `SlotReadings.of` 給出計時 `/RID=` 的時刻與牆上時間兩種讀法，全天、沒有 `/RID=`、主機在 UTC 時只有一種。驗證：`SlotReadingsTests`，標記 `spec-example: undo-history-discard / the two readings of an identifier`。
- [x] 1.2 `place(among:)` 只在恰好一種讀法是場次時採用它（兩種都是、都不是：不放）；四種頻率、`+08:00` 與 `-08:00`。驗證：`SlotReadingsTests`。

## 2. 擷取與還原

- [x] 2.1 擷取在任一讀法落在視窗內時記錄修改場次。驗證：`SeriesExceptionsTests.testAnOccurrenceAtTheWindowEndIsLeftToTheRuleWhetherPlainOrEdited`（改寫，三個主機時區）與 `FloatingSeriesExceptionsUndoTests.testTheFourWindowEdgeShapes`。
- [x] 2.2 還原在重建系列的場次（必要時加 14 小時邊界）上放置每筆紀錄，放在視窗外的丟掉，有一筆放不上去就整個不套用。驗證：`FloatingSeriesExceptionsUndoTests`（F1、D2、R2、放不上去、四種邊界形狀），標記 `spec-example: undo-history-discard / a floating edit comes back`。
- [x] 2.3 沒有兩種讀法的紀錄時，還原與 #527 之前的寫入與列出完全相同。驗證：`UndoSlotComparisonEquivalenceTests` 維持綠。

## 3. #321 的檢查

- [x] 3.1 兩邊所有讀法互相比對，只有同一系列的場次算數；最寬的時差（+14、−12、+05:45）上錯的讀法不是任何場次。驗證：`OccurrenceSlotGuardTests` 新增三個測試、`FloatingSeriesExceptionsUndoTests` 的 MA 兩個測試，標記 `spec-example: undo-history-discard / MA writes one event`。

## 4. 公開文字與文件

- [x] 4.1 `delete_event`、`delete_events_batch`、`undo` 的描述與 manifest 的 `undo` 摘要說明兩種讀法。驗證：`ManifestParityTests.testUndoSurfacesSayHowAnOccurrenceEditedWithoutATimeZoneIsRead`。
- [x] 4.2 README、README_zh-TW、CHANGELOG、release gate（rule 檔）。驗證：對照裝置結果逐句讀過。

## 5. 證明

- [x] 5.1 mutation 逐一看到變紅。驗證：PR body 的 mutation 表。
- [x] 5.2 全套 `swift test` 在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 failures；`main` 的測試名稱沒有少。
- [x] 5.3 iCloud 裝置格 F1、D1、D2、L1、U1、R2、MA、Z1。驗證：PR body 的裝置表。
