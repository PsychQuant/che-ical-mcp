<!--
沒有 [P]：每個 task 都以 build 或測試結束，這台機器一次只跑一個 build（共用的 build 鎖）。
測試先寫；每個新分支拿掉時要看到對應的測試失敗（紅），記在 PR body 的 mutation 表。
-->

## 1. 比對（純函式，`OccurrenceDateMatch.swift`）

- [ ] 1.1 `OccurrenceDateMatch.matches(requested:start:startIsAllDay:zone:eventIdentifier:externalIdentifier:occurrenceDate:seriesIsAllDay:host:)`：場次的開始以場次自己的旗標比對；原日以 `UndoPostState.ruleSlot(..., isAllDay: seriesIsAllDay, zone: host)` 讀出，以 `seriesIsAllDay` 比對；`host` 同時交給 `startsOnRequestedDay(host:)`。先以 `main` 的讀法（`originalSlot`）建立，看到下列測試紅，再改。驗證：`OccurrenceDateMatchTests` 五個主機時區的表格（requirement「Occurrence date names the occurrence's shown day or its original day」的 example），計時系列單獨改成全天的場次（UTC+8），在每個 process 時區（主機、`TZ=UTC`、`TZ=America/Los_Angeles`）都先紅後綠。

## 2. 接線（`FirstRemainingOccurrence.swift`）

- [ ] 2.1 `occurrenceDateMatches` 讀系列物件（`seriesObject(ofOccurrence:)`）的 `isAllDay`，讀不到時用場次的，呼叫 `OccurrenceDateMatch.matches`，主機時區 `.current`。驗證：`OccurrenceDateMatchWiringTests` 釘住函式本體（呼叫純函式一次、`seriesIsAllDay` 來自 `seriesObject(ofOccurrence:)`、後備是 `occurrence.isAllDay`、不再呼叫 `originalSlot`），先紅後綠；完整 `swift test` 三個時區 0 failures。

## 3. 文字

- [ ] 3.1 `CHANGELOG.md` `[Unreleased]` 的 Fixed 一條，寫量到的與沒量到的；`update_event`／`delete_event` 的描述已寫「occurrence_date must be that occurrence's day」，確認沒有與修正衝突的句子。驗證：內容複核；`ManifestParityTests` 不受影響。
- [ ] 3.2 release gate：`.claude/rules/mcp-binary-version-testing.md` 新增一節，列本 PR 在裝置上做過的格子與出版前要用出版的 binary 重做的格子。驗證：內容複核。

## 4. 證明

- [ ] 4.1 移除測試檢查（對 `origin/main` 以 (檔案, 名稱) 比對）、mutation 表（每個新分支一個 mutant，看到紅）。
- [ ] 4.2 裝置格（`--cli`、Developer ID 簽章的 release build、iCloud、名稱含 `#543` 的拋棄式日曆）：全天每週系列、一個場次單獨移兩天後，經它自己的識別碼帶 `notes`：`TZ=America/Los_Angeles` 與主機時區下原日被接受、前一天被拒絕；計時系列中單獨改成全天的場次的 `/RID=` 讀回。結束後依 id 刪除日曆，`probecount.py` 隔一分鐘兩次。
