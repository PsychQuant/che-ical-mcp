## 1. 先驗證設計的還原那一半（spike，失敗就回頭改 design）

- [x] 1.1 在 iCloud 拋棄式日曆（名稱含 `#285`）做 spike：建一個每週 ×4 系列、單獨刪第 3 場、單獨編輯第 2 場、整個系列刪除、手動重建系列，再對新系列移除多餘時段並以一次性事件重建被編輯的場次。行為：確認「重建後對剛建好的系列移除個別場次」與「以 `/RID=` 時段建立一次性事件」在 EventKit 上確實可行，且順序（先排除、再建一次性事件）不會讓排除多移除或少移除。驗證：結果與觀察到的寫入順序以留言貼在 #285；若任一步不成立，停止並回頭修改 design.md 的「undo 還原：重建 → 以視窗限定的差集排除 → 重建 detached」，不繼續往下做。同一個 spike 也讀規則：只刪最後一場、再整個系列刪除，在兩步之間各讀一次規則的 `count`，把 design 的「尾端刪除是推論」變成已驗證或已推翻的事實，兩個 `count` 值貼在 #285，並據此更新 design.md 的 Risks / Trade-offs 與 proposal.md 的案例 4 敘述。

## 2. 純函式（先寫測試，看它失敗，再實作）

- [x] 2.1 新增 `SeriesExceptions` 值型別（`window`、`keptSlots`、`detached`，含 `DetachedOccurrence { slot, snapshot }`），並在 `EventSnapshot` 加選用欄位 `exceptions`（init 參數預設 `nil`）。行為：既有 `EventSnapshot(from:)` 呼叫點不需修改即可編譯，未帶 `exceptions` 的快照與以前完全相同。驗證：先寫的 `SeriesExceptionsTests`（紅燈）確認預設為 `nil`，實作後轉綠；`swift test` 其餘測試不受影響。
- [x] 2.2 實作例外擷取的純函式：輸入視窗內實際場次的值（時段、是否 detached、識別碼）、輸出 `SeriesExceptions`；detached 場次的原始時段取自 `UndoPostState.originalSlot`（`/RID=`），沒有 `/RID=` 時退回 `occurrenceDate`。行為：未分離的場次進 `keptSlots`，detached 進 `detached` 且帶去掉規則的快照。驗證：`SeriesExceptionsTests` 涵蓋含 `/RID=` 的識別碼、缺 `/RID=` 的退回、全部未分離、全部 detached。
- [x] 2.3 實作「多餘時段」差集純函式：輸入重建後展開的時段、`keptSlots`、`window`，輸出要排除的時段；只在 `window` 內判斷，時段以 `UndoPostState.sameInstant`（到秒）比對。行為：中間被刪除的場次出現在輸出；視窗外的場次**不**出現；規則已縮短（尾端刪除）時輸出為空。驗證：`SeriesExceptionDifferenceTests`（紅燈後轉綠）涵蓋中間刪除、尾端刪除、視窗邊界上下各一秒、DST 轉換前後與非台北時區（例如 `America/New_York`）。

## 3. 刪除前擷取（例外記在系列快照上，取自「刪除前列舉的實際場次」）

- [ ] 3.1 新增窄的 `*Source` 縫（命名 `<Domain>Source`，不擴充 `EventKitManaging`），提供「列舉某系列在視窗內的實際場次」，預設注入 `EventKitManager.shared`。行為：擷取與還原都經此縫讀取場次，測試可注入假實作。驗證：`FakeEventKitManager` 風格的測試替身可編譯並在 handler 測試中使用。
- [ ] 3.2 在 `DeletedEventSnapshots`（`deleteEvent` 的整個系列分支）、`deleteEventSeries`、`deleteEventSeriesBatch` 三個記錄點，於 `eventStore.remove` 之前、僅當 `hadRules && span != .thisEvent` 時擷取 `SeriesExceptions` 並放進系列快照；擷取不能執行（沒有識別碼或日曆）時 `exceptions` 為 `nil`。行為：三個記錄點的快照一致帶著例外；span "this" 不擷取。驗證：先寫的 handler 測試（紅燈）經假的 `*Source` 驗證三個記錄點各自記到預期的 `keptSlots` 與 `detached`，以及不能執行時為 `nil`。

## 4. undo 還原（部分失敗：全有或全無，補償失敗要報告而不是吞掉）

- [ ] 4.1 先寫 `.deleteEvent` 分支的 handler 測試（紅燈）：記錄帶 `exceptions` 時，undo 依序「建立並 `save` 系列 → 列舉新系列視窗內場次 → 以差集排除 → 重建 detached 為一次性事件」。行為與驗證：測試斷言寫入順序、被排除的時段、被重建的一次性事件的欄位（標題等編輯內容），以及視窗外的場次未被碰到。
- [ ] 4.2 實作 `.deleteEvent` 分支的還原：沿用 `ExclusionExecutor.run`（`resolve` 找到該時段的場次、`remove` 與 #182 建立路徑相同的呼叫、`rollback` 補償刪除重建的系列），再建立一次性事件；`exceptions == nil` 時走舊行為。行為：requirement `Stale and busy protection` 下的「Delete of a whole series restores its exceptions (#285)」場景成立。驗證：4.1 的測試轉綠；`exceptions == nil` 的舊行為測試（`DeleteUndoTests` 既有案例）不變。
- [ ] 4.3 實作失敗處置：排除或建立一次性事件失敗時，補償刪除重建的系列與已建的一次性事件，丟可重試錯誤；補償本身失敗時丟 `UnrecoverableUndoError`，訊息說明系列已存在且部分例外已套用。行為：「Restoring the exceptions fails part-way (#285)」場景成立，且絕不回報成功。驗證：測試以假 `*Source` 注入「第 k 次排除失敗」、「第 k 個一次性事件失敗」、「補償失敗」三種情況，斷言錯誤種類、store 狀態與紀錄是否放回（可重試放回、補償失敗丟棄）；批次成員失敗沿用 #248，`UndoBatchRestoreTests` 補一個成員為帶例外系列的案例。

## 5. 重複防護（時段已被系列場次佔用就不寫入）

- [ ] 5.1 先寫測試（紅燈）再實作 `.deleteOccurrence` 分支：寫入一次性事件前，在快照日曆查找同一時段（`sameInstant`）、同標題、`hasRecurrenceRules` 的事件，有就不寫入、回 `success: true` 並說明「該場次已由系列還原」，紀錄照常用掉。行為：「Occurrence delete whose slot the series already holds (#285)」場景成立，且時段未被佔用時行為不變。驗證：handler 測試涵蓋「被佔用不寫入」「未被佔用照寫」「批次成員同樣適用」，以及診斷案例 1 的兩次 undo 只留下一個事件。

## 6. 揭露（訊息與說明如實反映視窗）

- [ ] 6.1 重寫 `DeleteUndo.swift` 的 `seriesRulesRestoreNote`、`seriesRulesListingNote` 與還原訊息：區分「有例外且已還原」「沒有例外」「無法檢查」三種，並說明視窗外與刪除之後才產生的例外看不到；`undo_history` 與批次的列表文字依 spec 的新場景。行為：「Occurrences outside the checked window (#285)」場景成立，且沒有任何文字宣稱「不會有多餘場次」。驗證：`DeleteUndoTests` 與 `UndoRedoTextHandlerTests` 的字串斷言更新（先紅後綠），含批次的 K 只算不帶例外的成員。
- [ ] 6.2 更新 `Server.swift` 內 `undo`、`delete_event`、`delete_events_batch` 的 tool 描述，移除「span 'all' 尚未檢查」的字樣並改述新行為。行為：描述與實際行為一致。驗證：既有的描述快照或 `ManifestParityTests` 類測試通過；人工對照 `Server.swift` 描述與 spec 場景逐句核對。

## 7. 文件與規格 [P]

- [ ] 7.1 [P] 把 `restore-series-exceptions-on-delete-undo` 的 delta 合併進 `openspec/specs/undo-history-discard`（歸檔時），並確認 `recurrence-excluded-dates` 只是重用內部機制、不需修改。行為：兩份 spec 對「排除」的敘述不互相矛盾。驗證：`spectra validate` 通過；對照 `recurrence-excluded-dates` 的需求逐條確認未被牽動，結論寫在 #285 的實作留言。
- [ ] 7.2 [P] 更新 `README.md`、`README_zh-TW.md`、`plugin/README.md` 與兩份 `CHANGELOG.md` 的 `[Unreleased]`：說明整個系列刪除的 undo 現在還原視窗內的例外、編輯過的場次以一次性事件還原、以及視窗限制。行為：文件與新行為一致且不宣稱超出視窗的保證。驗證：doc-sync 掃描（`git ls-files` 的 README*／CLAUDE.md）逐檔確認無過時敘述；`ManifestParityTests` 與版本一致性測試不受影響。

## 8. 驗證

- [ ] 8.1 完整測試：`swift test` 在本機時區與 `TZ=UTC` 各跑一次，並記錄失敗的測試名稱（#315 的教訓）。行為：沒有新增失敗。驗證：兩次輸出的 `Executed N tests, with 0 failures` 貼在實作留言。
- [ ] 8.2 iCloud 實機（重啟後的 session MCP，先以行為探測確認載入的是新版）：診斷的案例 1（兩次 undo 只留一個事件）、案例 2（編輯過的場次以一次性事件還原）、案例 3（span "all" 含中間刪除與編輯）、案例 4（尾端刪除不多排除）。行為：與 spec 場景一致。驗證：每案例的讀回結果（由另一個行程以新的 store 讀取）貼在 #285，日曆用完以 id 清掉並以計數確認殘留為 0。
- [ ] 8.3 Google 與 DST／非台北時區實機：案例 1、2 在 Google 日曆各跑一次；在跨 DST 的系列與非台北時區事件各跑一次案例 3。行為：還原結果與 iCloud 一致，或差異被記錄並進揭露文字。驗證：結果貼在 #285；Google 日曆需由使用者在網頁建立並刪除拋棄式日曆（EventKit 不允許在 Google 建立日曆）。
