## 1. 先驗證設計的還原那一半（spike，失敗就回頭改 design）

- [x] 1.1 在 iCloud 拋棄式日曆（名稱含 `#285`）做 spike：建一個每週 ×4 系列、單獨刪第 3 場、單獨編輯第 2 場、整個系列刪除、手動重建系列，再對新系列移除多餘時段並以一次性事件重建被編輯的場次。行為：確認「重建後對剛建好的系列移除個別場次」與「以 `/RID=` 時段建立一次性事件」在 EventKit 上確實可行，且順序（先排除、再建一次性事件）不會讓排除多移除或少移除。驗證：結果與觀察到的寫入順序以留言貼在 #285；若任一步不成立，停止並回頭修改 design.md 的「undo 還原：重建 → 以視窗限定的差集排除 → 重建 detached」，不繼續往下做。同一個 spike 也讀規則：只刪最後一場、再整個系列刪除，在兩步之間各讀一次規則的 `count`，把 design 的「尾端刪除是推論」變成已驗證或已推翻的事實，兩個 `count` 值貼在 #285，並據此更新 design.md 的 Risks / Trade-offs 與 proposal.md 的案例 4 敘述。

## 2. 純函式（先寫測試，看它失敗，再實作）

- [x] 2.1 新增 `SeriesExceptions` 值型別（`window`、`keptSlots`、`detached`，含 `DetachedOccurrence { slot, snapshot }`），並在 `EventSnapshot` 加選用欄位 `exceptions`（init 參數預設 `nil`）。行為：既有 `EventSnapshot(from:)` 呼叫點不需修改即可編譯，未帶 `exceptions` 的快照與以前完全相同。驗證：先寫的 `SeriesExceptionsTests`（紅燈）確認預設為 `nil`，實作後轉綠；`swift test` 其餘測試不受影響。
- [x] 2.2 實作例外擷取的純函式：輸入視窗內實際場次的值（時段、是否 detached、識別碼）、輸出 `SeriesExceptions`；detached 場次的原始時段取自 `UndoPostState.originalSlot`（`/RID=`），沒有 `/RID=` 時退回 `occurrenceDate`。行為：未分離的場次進 `keptSlots`，detached 進 `detached` 且帶去掉規則的快照。驗證：`SeriesExceptionsTests` 涵蓋含 `/RID=` 的識別碼、缺 `/RID=` 的退回、全部未分離、全部 detached。
- [x] 2.3 實作「多餘時段」差集純函式：輸入重建後展開的時段、`keptSlots`、`window`，輸出要排除的時段；只在 `window` 內判斷，時段以 `UndoPostState.sameInstant`（到秒）比對。行為：中間被刪除的場次出現在輸出；視窗外的場次**不**出現；規則已縮短（尾端刪除）時輸出為空。驗證：`SeriesExceptionsTests` 的差集案例（紅燈後轉綠）涵蓋中間刪除、尾端刪除、視窗邊界上下各一秒、DST 轉換前後與非台北時區（例如 `America/New_York`）。

## 3. 刪除前擷取（例外記在系列快照上，取自「刪除前列舉的實際場次」）

- [x] 3.1 把「列舉視窗內實際場次」與其後的決策分開：EventKit 讀取在 `EventKitManager+SeriesExceptions.swift` 的薄層，決策是純函式 `SeriesExceptionsPlanner.capture`／`surplusSlots` 與以 closure 為縫的 `SeriesExceptionsRestorer`（#182 `ExclusionExecutor` 的 closure-seam 變體，不新增 `*Source` 協定、不擴充 `EventKitManaging`）。行為：擷取與還原的決策不依賴 EventKit，測試可注入假 closure。驗證：`SeriesExceptionsTests`、`SeriesExceptionsRestorerTests` 以純值與 closure 驅動並通過。
- [x] 3.2 在 `DeletedEventSnapshots`（`deleteEvent` 的整個系列分支）、`deleteEventSeries`、`deleteEventSeriesBatch` 三個記錄點，於 `eventStore.remove` 之前、僅當 `hadRules && span != .thisEvent` 時擷取 `SeriesExceptions` 並放進系列快照；擷取不能執行時 `exceptions` 為 `nil`。行為：三個記錄點的快照一致帶著例外；span "this" 不擷取。驗證：決策為純函式（`SeriesExceptionsPlanner.capture`，`SeriesExceptionsTests`）；EventKit 擷取層以 iCloud 實機驗證（案例 1–4、`delete_events_batch` span all）。**沒有**經 handler 縫的記錄點測試（本 change 用 closure 縫而非 `*Source` 協定），這是已知的覆蓋缺口，列為 PR #318 verify 的後續項目。

## 4. undo 還原（部分失敗：全有或全無，補償失敗要報告而不是吞掉）

- [x] 4.1 `.deleteEvent` 分支的還原順序測試：「移除多餘時段 → 重建 detached 為一次性事件」。行為與驗證：`SeriesExceptionsRestorerTests` 以 closure 日誌斷言寫入順序、被排除的時段、被重建的一次性事件，以及視窗外的場次未被碰到；`executeUndo` 分支本身的接線沒有 handler 測試，由實機驗證。
- [x] 4.2 實作 `.deleteEvent` 分支的還原：沿用 `ExclusionExecutor.run`（`resolve` 找到該時段的場次、`remove` 與 #182 建立路徑相同的呼叫、`rollback` 補償刪除重建的系列），再建立一次性事件；`exceptions == nil` 時走舊行為。行為：requirement `Stale and busy protection` 下的「Delete of a whole series restores its exceptions (#285)」場景成立。驗證：4.1 的測試轉綠；`exceptions == nil` 的舊行為測試（`DeleteUndoTests` 既有案例）不變。
- [x] 4.3 失敗處置：排除或建立一次性事件失敗時，補償刪除重建的系列與已建的一次性事件（含 save 丟錯但可能已寫入者），丟可重試錯誤；補償本身失敗時丟 `UnrecoverableUndoError`。行為：「Restoring the exceptions fails part-way (#285)」場景成立，且絕不回報成功。驗證：`SeriesExceptionsRestorerTests` 涵蓋第 k 次排除失敗、第 k 個一次性事件失敗、寫入後丟錯、補償失敗、一次性事件清理失敗。`UndoBatchRestoreTests` 的「成員為帶例外系列」案例**尚未寫**，列為後續項目。

## 5. 重複防護（時段已被系列場次佔用就不寫入）

- [x] 5.1 `.deleteOccurrence` 分支重複防護：寫入前查找同一時段（`sameInstant`）、同標題、`hasRecurrenceRules` 的事件，有就不寫入、回 `success: true` 並說明。行為：「Occurrence delete whose slot the series already holds (#285)」場景成立，且時段未被佔用時行為不變。驗證：`OccurrenceSlotGuardTests`（純判斷）與 iCloud 實機（視窗外場次：不寫入、無重複；視窗內：寫入一次性事件）。沒有 handler 層測試與批次成員測試。

## 6. 揭露（訊息與說明如實反映視窗）

- [x] 6.1 重寫 `DeleteUndo.swift` 的 `seriesRulesRestoreNote`、`seriesRulesListingNote` 與還原訊息：區分「有例外且已還原」「沒有例外」「無法檢查」三種，並說明視窗外與刪除之後才產生的例外看不到；`undo_history` 與批次的列表文字依 spec 的新場景。行為：「Occurrences outside the checked window (#285)」場景成立，且沒有任何文字宣稱「不會有多餘場次」。驗證：`DeleteUndoTests`（既有字串斷言隨新措辭更新）與新增的 `SeriesExceptionsTextTests`（單筆、批次、混合批次的列表與 undo 文字）；`ManifestParityTests` 釘住描述與 manifest 摘要。
- [x] 6.2 更新 `Server.swift` 內 `undo`、`delete_event`、`delete_events_batch` 的 tool 描述，移除「span 'all' 尚未檢查」的字樣並改述新行為。行為：描述與實際行為一致。驗證：既有的描述快照或 `ManifestParityTests` 類測試通過；人工對照 `Server.swift` 描述與 spec 場景逐句核對。

## 7. 文件與規格 [P]

- [x] 7.1 [P] （一致性已核對：`recurrence-excluded-dates` 的需求只涵蓋建立時的排除與 createEvent 的 undo，與本 change 重用同一個 executor 但不互相矛盾，無需修改）把 `restore-series-exceptions-on-delete-undo` 的 delta 合併進 `openspec/specs/undo-history-discard`（歸檔時），並確認 `recurrence-excluded-dates` 只是重用內部機制、不需修改。行為：兩份 spec 對「排除」的敘述不互相矛盾。驗證：`spectra validate` 通過；對照 `recurrence-excluded-dates` 的需求逐條確認未被牽動，結論寫在 #285 的實作留言。
- [x] 7.2 [P] 更新 `README.md`、`README_zh-TW.md`、`plugin/README.md` 與兩份 `CHANGELOG.md` 的 `[Unreleased]`：說明整個系列刪除的 undo 現在還原視窗內的例外、編輯過的場次以一次性事件還原、以及視窗限制。行為：文件與新行為一致且不宣稱超出視窗的保證。驗證：doc-sync 掃描（`git ls-files` 的 README*／CLAUDE.md）逐檔確認無過時敘述；`ManifestParityTests` 與版本一致性測試不受影響。

## 8. 驗證

- [x] 8.1 完整測試：`swift test` 在本機時區與 `TZ=UTC` 各跑一次，並記錄失敗的測試名稱（#315 的教訓）。行為：沒有新增失敗。驗證：兩次輸出的 `Executed N tests, with 0 failures` 貼在實作留言。
- [x] 8.2 （2026-10-12 完成；以簽名的新 binary 作單一長駐 stdio 行程、另一行程讀回，等同乾淨表面；案例 1 的預期已更正，見 proposal）iCloud 實機（重啟後的 session MCP，先以行為探測確認載入的是新版）：診斷的案例 1（兩次 undo 只留一個事件）、案例 2（編輯過的場次以一次性事件還原）、案例 3（span "all" 含中間刪除與編輯）、案例 4（尾端刪除不多排除）。行為：與 spec 場景一致。驗證：每案例的讀回結果（由另一個行程以新的 store 讀取）貼在 #285，日曆用完以 id 清掉並以計數確認殘留為 0。
- [ ] 8.3 Google 與 DST／非台北時區實機：案例 1、2 在 Google 日曆各跑一次；在跨 DST 的系列與非台北時區事件各跑一次案例 3。行為：還原結果與 iCloud 一致，或差異被記錄並進揭露文字。驗證：結果貼在 #285；Google 日曆需由使用者在網頁建立並刪除拋棄式日曆（EventKit 不允許在 Google 建立日曆）。

## 9. PR #318 verify 修正（2026-10-12）

- [x] 9.1 修正三個必修缺陷：B1 列舉範圍加寬並一律依規則時段判斷（`listingRange`、`capture`）、B2 系列第一場永不移除（`SeriesExceptionsRestorer` anchor）、B3 save 丟錯後的一次性事件一併清理（`SeriesExceptionsOneOffWriteFailed`）。驗證：`SeriesExceptionsTests`、`SeriesExceptionsRestorerTests` 新增 9 項；mutation check（拿掉 anchor 與拿掉 write-then-throw 清理）3 項失敗後還原；iCloud 實機 B1 通過（移出視窗約 70 天的編輯場次以一次性事件回來）；B2 在 iCloud 到不了還原階段（第一場被單獨編輯後系列刪除本身即失敗，#284），僅單元測試。
- [x] 9.2 對齊文字與文件：`seriesRulesRestoreNote`、`seriesExceptionsRestoredNote`（第一場與移出範圍的說明）、`docs/UNDO_HISTORY.md`、spec（一次性事件建在編輯後開始時間、第一場與跨視窗邊界兩個新場景）、design。
- [x] 9.4 PR #318 第二輪 verify 修正（FAIL，3 組必修）：A 邊界改為三段獨立查詢（四年上限是每個查詢各自算）；B 擷取為空回 nil，還原前核對紀錄與重建系列是否對得上、對不上就只依規則並說明；anchor 改用重建系列的起點；C 系列回復與一次性事件清理分開回報（`strayOneOffs`、`oneOffMaybeLeft`）。驗證：`SeriesExceptionsTests`／`SeriesExceptionsRestorerTests`／`SeriesExceptionsTextTests` 新增 8 項；mutation check（拿掉一致性檢查、拿掉邊界查詢）失敗後還原；尚未做的實機：開放式／依次數結束系列的邊界（見實作留言）。
- [ ] 9.3 後續項目（尚未處理，不在本 PR）：重複防護的誤判取捨（同標題同時段的另一個重複事件）、`UndoBatchRestoreTests` 的帶例外成員案例、批次 undo 文字在 guard 略過成員時的敘述、每次系列刪除的列舉成本、Google／DST 實機（8.3）。
