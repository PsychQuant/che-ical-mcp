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

## 5. 刪除時的預告（計畫第 6 步）

- [ ] 5.1 擷取之後，把記下的修改場次放到規則從第一個場次展開的場次上（`DeletedOccurrenceCheck.expansion`，展開到最後一個視窗結束後 14 小時），數出放不上去的筆數；規則不只一條、展開器不跟的規則、場次太多、第一個場次讀不出來時不給數字。驗證：`SeriesDeleteForecastTests`。
- [ ] 5.2 四個擷取點（`delete_event` span `all`、從第一個場次起的 span `future`、`delete_events_batch` span `all` 的系列列、span `future` 刪掉整個系列的列）在移除之前算出筆數，第一個場次經替身讀到或第一個場次自己被改過時不算（`wholeSeriesBaseline` 為 `.stored` 才算）；只有記錄是整個系列的刪除時才往外傳；批次裡有一列讓整個 undo 拒絕時，所有列都不給。驗證：`SeriesDeleteForecastWiringTests`、`SeriesDeleteForecastTests`。
- [ ] 5.3 `delete_event` 的回應、批次實際呼叫的 `rules_alone_on_undo` 列、`span: all` 試跑的列寫 `undo_note`；與 #436、#452 的 `undo_note` 不會互相覆蓋。驗證：`SeriesDeleteForecastHandlerTests`。
- [ ] 5.4 描述、manifest、README、CHANGELOG、release gate 說明預告。驗證：`ManifestParityTests`、`SlotReadingsDocsTests`。

## 6. 證明

- [ ] 6.1 mutation 逐一看到變紅（計畫的 mutant 1–9、12、13，以及每個新分支與新文字一個）。驗證：PR 說明的 mutation 表。
- [ ] 6.2 全套 `swift test` 在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 failures（最後的 head）；`main` 的測試名稱沒有少，改寫的測試列出理由。
- [ ] 6.3 iCloud 裝置格（最後的 head 的簽章 release build）。驗證：PR 說明的裝置表。
