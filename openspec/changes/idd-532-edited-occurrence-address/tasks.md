<!--
ASSUMPTION: 沒有任何 task 帶 [P]，雖然 parallel_tasks 開著：每個 task 都以 build 或測試結束，
這台機器一次只跑一個 build（共用的 build 鎖），所以沒有可以平行的。
每一組的測試先寫、先看到失敗，再寫同一組的程式。
-->

## 1. 先寫測試（紅）

- [ ] 1.1 `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift` 的純函式測試寫出：對某一天收集到哪些被單獨修改過的場次、每一種拒絕訊息的全文。帶標記 `spec-example: edited-occurrence-addressing / Edited in place`、`/ Moved off the day`、`/ Two for one day`、`/ Update with span future`、`/ Delete with span future`、`/ Move row`、`/ Identifier outside the allowed characters`、`/ Local day in the not-found text`、`/ Series that cannot be listed`，以及 `spec-example: recurrence-excluded-dates / Edited occurrence on an excluded date`、`/ Occurrence moved onto an excluded date`、`/ Occurrence moved off an excluded date`。驗證：`swift test --filter EditedOccurrenceAddressTests` 對 stub 以 assertion 失敗。
- [ ] 1.2 `Tests/CheICalMCPTests/EditedOccurrenceAddressHandlerTests.swift` 的 handler 測試寫出：`update_event`、`delete_event` 與 `move_events_batch` 的一列（其他列照常）把拒絕原因原樣交給呼叫端；呼叫期間擷取的 stderr 是空的，而同一個擷取下不受信任的錯誤會寫一行；`create_event` 與 `create_events_batch` 的一列回衝突錯誤、不回 `skipped`。帶標記 `spec-example: edited-occurrence-addressing / Stderr stays empty`。驗證：`swift test --filter EditedOccurrenceAddressHandlerTests`。
- [ ] 1.3 `Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift` 的原始碼釘選：`updateEvent`、`deleteEvent`、`moveEvent` 裡，找被修改場次的呼叫只在 `findOccurrence` 落空的分支內，在找不到的 throw 之前，也在任何賦值、存檔、移除之前；span 在兩個同時接受兩種 span 的呼叫點傳到訊息產生器；`createEvent` 的排除迴圈問當天的檢查並丟 `exclusionConflict`；兩個找不到的 throw 經格式化函式印日期；共用的 span `future` 句子在 `Sources/` 只寫一次。帶標記 `spec-example: edited-occurrence-addressing / A plain occurrence still resolves`。驗證：`swift test --filter EditedOccurrenceAddressWiringTests` 在第 2、3 組的程式之前失敗。
- [ ] 1.4 `Tests/CheICalMCPTests/ManifestParityTests.swift` 新增一個測試：`update_event`、`delete_event`、`move_events_batch` 的說明（served description 與 `mcpb/manifest.json` 的摘要）都寫到系列識別碼加日期指不到被單獨修改過的場次、答案會給出它的識別碼；`create_event` 與 `create_events_batch` 的 `excluded_occurrence_dates` 說明寫到衝突與限制。驗證：該測試在第 4 組之前失敗。

## 2. 純型別

- [ ] 2.1 `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift` 對當天的事件與系列列出的場次，回傳屬於要求那一天、被單獨修改過的場次（requirement「Series identifier and day do not address an edited occurrence」），每個一次、依開始時間排序（requirement「Several edited occurrences are all listed」）；沒有符合的或系列沒列出時回空。驗證：1.1 的收集測試通過。
- [ ] 2.2 同一個檔案依工具與 span 產生拒絕訊息（requirement「Span future refusals say what the identifier takes」、requirement「Move row names event_ids and the start day」），只在允許字元清單內才寫出識別碼（requirement「Identifier echoed only in a known shape」），並用給定的時區產生找不到的訊息細節（requirement「Not-found answer prints the local day」）。span `future` 的句子讀自 `Sources/CheICalMCP/EventKit/DetachedOccurrenceSpan.swift` 的常數，#416 的訊息也讀同一個，而且 #416 的訊息逐位元組不變。驗證：1.1 的訊息測試通過，`swift test --filter DetachedOccurrenceSpanTests` 不改就通過。

## 3. 呼叫端

- [ ] 3.1 `Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift` 用一個 internal 函式把系列列出的場次交給搜尋，不改列出的方式；`Sources/CheICalMCP/EventKit/EventKitManager.swift` 新增搜尋 helper（當天列舉一次加系列列出一次，只在落空之後跑）。驗證：build 通過，1.3 的釘選通過。
- [ ] 3.2 `updateEvent`、`deleteEvent`、`moveEvent` 在搜尋找到被修改的場次時回拒絕，否則回帶當地日期的找不到；原因是受信任的錯誤訊息（requirement「Refusal reasons stay off stderr」）。驗證：1.2 與 1.3 通過。
- [ ] 3.3 `createEvent` 的排除檢查在既有系列被修改過的場次於要求的日期開始時，把那個日期算作仍然存在（requirement「Idempotent retry and conflict detection」），只讀那一天。驗證：1.1、1.2 的排除測試與 1.3 的釘選通過。

## 4. 文字與文件

- [ ] 4.1 `Sources/CheICalMCP/Server.swift` 的工具說明與 `mcpb/manifest.json` 的摘要寫出新的答案，不含角括號與 ampersand。驗證：1.4 與 `testServedToolTextHasNoXMLMetacharacters` 通過。
- [ ] 4.2 `README.md`、`README_zh-TW.md`、`CHANGELOG.md` 說明拒絕、排除日的衝突、限制與當地日期；`.claude/rules/mcp-binary-version-testing.md` 改好 #416 第 2 步那一句，並新增含裝置格的 release gate 一節。驗證：1.3 的文件釘選（每個片語在該文件只出現一次）通過。

## 5. 整套檢查

- [ ] 5.1 整套測試在 host 時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都通過，`main` 上有的測試函式一個都沒少。驗證：三次 `swift test`，以及與 `main` 比對（檔案、測試名）。
- [ ] 5.2 Implementation Plan 的 13 個 mutation 各至少讓一個測試變紅，之後還原。驗證：mutation、失敗的測試、結果的表。
- [ ] 5.3 Implementation Plan 的裝置格用簽章過的 release build 經 `--cli` 在拋棄式日曆上跑，每個拒絕之後照訊息再打一次並記錄答案，日曆刪除後計數兩次。驗證：記錄下來的表。
