## Context

整個系列刪除（`delete_event` span "future" 從第一場起、span "all"、`delete_events_batch`、`deleteEventSeries*`）記錄的是系列物件的 `EventSnapshot`：欄位加 `recurrenceRules`，沒有場次層級的狀態。`undo` 的 `.deleteEvent` 分支建新事件、套用快照、`save`，由 EventKit 依規則展開，所以規則會生成的時段全部回來：

- 早先單獨刪除的場次（例外日期）回來；
- 單獨編輯過的場次（detached）在系列刪除時一起被移除，還原後只剩系列的普通場次。

`.deleteOccurrence` 分支（先前的單一場次刪除）無條件寫入一次性事件，所以重複 undo 會在同一時段留下兩個事件。

已驗證的事實（2026-10-12，iCloud，拋棄式日曆；詳見 #285 診斷留言）：

- EventKit 公開標頭沒有例外日期 API。
- 刪除前，`enumerateEvents` 能列出系列實際存在的場次，附 `occurrenceDate`、`isDetached`；被編輯的場次的識別碼帶 `/RID=<自 2001-01-01 起的秒數>`，那是它原本的時段（#311 的 `originalSlot`）。
- 對中間一場單獨刪除不會改規則（`count` 仍是 4），例外存在規則之外。
- 已存在的 `ExclusionExecutor`（#182）對剛建立的系列做兩段式排除並補償刪除，`seriesScanWindow`（#259）已定義掃描視窗。

**已驗證（task 1.1 spike，2026-10-12，iCloud，同一個長駐行程）**：還原那一半成立：重建後對新系列移除多餘時段、再以一次性事件重建 detached 場次，最終只剩應有的系列場次加上一個一次性事件，被刪的場次沒有回來。**尚未驗證**：Google 與 DST／非台北時區。

## Goals / Non-Goals

**Goals:**

- 整個系列刪除後 `undo`：視窗內早先單獨刪除的場次**維持刪除**；視窗內單獨編輯過的場次以**帶編輯的一次性事件**還原。
- 先前單一場次刪除的 `undo` 發現時段已被系列場次佔用時**不寫入**，並說明。
- 任何中途失敗不留下「被排除一半的系列」。
- 所有訊息、`undo_history` 與 tool 描述如實說明還原了什麼、沒有還原什麼（視窗限制）。

**Non-Goals:**

- #279、#284（見 proposal）。
- 把編輯過的場次放回系列（EventKit 做不到）。
- 自己實作重複規則展開；例外一律取自「列舉的實際場次」與「EventKit 重建後的展開結果」的差集。
- 視窗外、或刪除之後才由別的用戶端造成的例外：看不到，只負責揭露。

## Decisions

### 例外記在系列快照上，取自「刪除前列舉的實際場次」

在 `EventSnapshot` 加一個選用欄位 `exceptions: SeriesExceptions?`（init 參數預設 `nil`，既有呼叫點不必改）。`SeriesExceptions` 是純值型別：

- `window: DateInterval`：掃描視窗，沿用 `UndoPostState.seriesScanWindow(firstStart:ruleEnd:)`；
- `keptSlots: [Date]`：視窗內、刪除前存在且**未分離**的場次的時段；
- `detached: [DetachedOccurrence]`：視窗內每個 detached 場次，含一份去掉規則的一次性 `EventSnapshot` 與它的原始時段（`UndoPostState.originalSlot`，即 `/RID=`）。

擷取只在 `hadRules && span != .thisEvent` 時進行（只有這些刪除會被分類成整個系列），三個記錄點（`deleteEvent`、`deleteEventSeries`、`deleteEventSeriesBatch`）共用一個函式，列舉方式與 `modifiedOccurrenceCount` 相同（同一個 predicate、`isOccurrence` 判斷屬於該系列）。

**備選：** 記下刪除當下已知的「例外日期」。沒有 API 可讀，只能靠「只涵蓋經由本 server 做的變更」的紀錄，漏掉 Calendar.app 與其他用戶端的變更；否決。**備選：** 自己展開規則算出「應存在的時段」再與實際場次比對。要重寫重複規則展開，且開放式系列掃不到盡頭；否決，改用「重建後讓 EventKit 展開」。

### undo 還原：重建 → 以視窗限定的差集排除 → 重建 detached

`.deleteEvent` 分支，當 `snapshot.exceptions != nil`：

1. 照舊建立並 `save` 系列。
2. 列舉**新系列**在 `window` 內的實際場次（EventKit 的展開結果）。
3. 多餘時段 = 展開結果中、時段不在 `keptSlots`（以 `sameInstant` 比對到秒）的場次。**只在 `window` 內判斷**，視窗外的場次一律不碰；否則視窗外的合法場次會被誤排除。
4. 用 `ExclusionExecutor.run`：`resolve` 找到該時段的場次、`remove` 以與 #182 建立路徑相同的呼叫移除、`rollback` 補償刪除整個重建出的系列。
5. 為每個 detached 場次建立一次性事件（沿用 #244 的 D1 先例）；它的時段已在步驟 3 因不在 `keptSlots` 而被排除。

`exceptions == nil`（擷取當時不能執行，例如系列沒有識別碼或日曆）時走舊行為與舊訊息，並如實說明「無法檢查例外」。

**備選 B（拒絕並丟棄有例外的系列的 undo，#244 D2 先例）：** 最穩、程式碼最少，但這類系列就沒有 undo；維護者選了 A。**備選 C（只防重複）：** 過度還原與編輯丟失仍在；維護者選了 A。

### 部分失敗：全有或全無，補償失敗要報告而不是吞掉

步驟 4 的兩段式與補償沿用 `ExclusionExecutor`（先解析全部、再移除；失敗時刪掉重建的系列）。步驟 5 若某個一次性事件建立失敗，同樣補償刪除重建的系列與已建的一次性事件，丟出**可重試**的錯誤（`handleUndo` 對它把紀錄放回去，重試不會留下半個結果）。補償本身失敗時，丟 `UnrecoverableUndoError`（紀錄丟棄，因為重試會再建一個系列），訊息說出系列已存在、部分例外已套用，請在 Calendar 檢查；絕不回報成功。批次內的成員失敗沿用 #248：成員自己的寫入已補償，因此算「未還原」，其餘成員的處置不變。

### 重複防護：時段已被系列場次佔用就不寫入

`.deleteOccurrence` 分支寫入一次性事件前，在快照的日曆內查找同一時段（`sameInstant` 的開始時間）、同標題、且 `hasRecurrenceRules` 的事件；有就**不寫入**，訊息說明「該場次已由系列還原」，紀錄照常用掉（這次 undo 的結果就是「已經在了」，不是失敗）。判斷依據是時間與標題，極少數情況（同日曆、同時段、同標題的另一個重複事件）可能誤判，這個限制寫在訊息之外的 spec 場景裡。

### 揭露：訊息與說明如實反映視窗

重寫 `seriesRulesRestoreNote`、`seriesRulesListingNote` 與 `undo`、`delete_event`、`delete_events_batch` 的描述：區分三種結果（有例外且已還原／沒有例外／無法檢查），並說明視窗外與刪除之後才產生的例外看不到。移除「span 'all' 尚未檢查」的字樣，那已在診斷驗證（行為與 span future 一致）。

## Implementation Contract

**可觀察的行為**

- 視窗內早先單獨刪除的場次，系列刪除再 `undo` 後仍然不存在。
- 視窗內單獨編輯過的場次，`undo` 後以**一次性事件**存在，標題與其他編輯內容保留，不再屬於系列。
- 先前單一場次刪除的 `undo`，遇到時段已被系列場次佔用：`success: true`、不寫入，`message` 說明該場次已由系列還原。
- `undo_history` 的整個系列刪除項目與批次項目，用語改為如實描述（見 spec）。

**資料形狀**

- `EventSnapshot.exceptions: SeriesExceptions?`；`SeriesExceptions { window: DateInterval; keptSlots: [Date]; detached: [DetachedOccurrence] }`；`DetachedOccurrence { slot: Date; snapshot: EventSnapshot }`（`snapshot` 不含規則）。
- 擷取函式與差集函式為**純函式**（輸入場次與時段的值型別、輸出時段清單），EventKit 讀取在薄的一層，以新的窄 `*Source` 縫注入（命名 `<Domain>Source`，不擴充 `EventKitManaging`）。

**失敗模式**

- 擷取不能執行：`exceptions == nil`，舊行為加如實說明；不丟錯。
- 排除失敗：補償刪除重建的系列，丟可重試錯誤，紀錄放回。
- 補償失敗：`UnrecoverableUndoError`，紀錄丟棄，訊息說明現況。
- 一次性事件建立失敗：同排除失敗。

**驗收**

- 單元：差集函式涵蓋中間刪除、尾端刪除（規則已帶著，不多排除）、視窗邊界（視窗外的場次不被排除）、DST 與非台北時區的時段比對；擷取函式涵蓋 detached 的原始時段來自 `/RID=`。
- handler：經假的 `*Source` 驗證 undo 的寫入順序、補償與錯誤處置，以及重複防護。
- 實機（iCloud）：診斷的案例 1、2、3；Google 與 DST 各至少跑一次。以 `--cli` 驗證不了 undo（每次呼叫是獨立行程、沒有 undo 堆疊），必須用重啟後的 session MCP 或單一長駐 stdio 行程（見 `.claude/rules/mcp-binary-version-testing.md`）。

**範圍界線**

- 範圍內：三個記錄點、`.deleteEvent` 與 `.deleteOccurrence` 的 undo 分支、批次還原、訊息與描述、spec、文件。
- 範圍外：#279、#284、reminder、`update_event`、`move_events_batch`。

## Risks / Trade-offs

- **還原那一半未端到端驗證。** 第一個任務是在 iCloud 上做 spike：對剛重建的系列排除多餘時段並建立一次性事件，確認寫入順序與結果；spike 失敗就回頭改設計，不繼續堆疊。
- **視窗限制。** 開放式或超過 1460 天的系列，視窗外的例外看不到，視窗外的場次維持 EventKit 的展開結果（即舊行為）。揭露文字必須說清楚，不能寫成「不會有多餘場次」。
- **尾端刪除已驗證（task 1.1，2026-10-12，iCloud）。** 刪最後一場後規則 `count` 從 4 變成 3，列出 3 場；刪中間一場則規則維持 4、列出 3 場。所以尾端刪除由規則攜帶、快照本來就有，差集（展開結果減 `keptSlots`）不會多排除；只有中間刪除成為規則之外的例外。
- **擷取時的狀態是快照。** 刪除之後別處造成的例外不在其中；undo 與刪除之間隔多久都一樣。
- **寫入量。** 一次 undo 可能做 N 次排除加 M 次建立，都在一次 undo 呼叫內；補償與批次語意（#248）已涵蓋失敗，但成功路徑的耗時隨例外數增加。
- **重複防護是啟發式。** 以時間、標題與「是重複事件」判斷佔用，極少數情況可能誤判。
