<!--
ASSUMPTION: 沒有任何 task 帶 [P]，雖然 parallel_tasks 開著：每個 task 都以 build 或測試結束，
這台機器一次只跑一個 build（共用的 build 鎖），所以沒有可以平行的。
測試先寫；每個新分支拿掉時要看到對應的測試失敗（紅），紀錄在 mutation 表。
-->

## 1. 純型別（`Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`）

- [x] 1.1 `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift` 寫出沒有時區的系列的測試（requirement「Series identifier and day do not address an edited occurrence」），帶標記 `spec-example: edited-occurrence-addressing / Floating series by start only`：週四 20:00 的系列、`/RID=819835200`、現在在週六開始、主機 Asia/Taipei，要求週五與週四都沒有符合的，要求週六有一個、沒有原本的日期，任何訊息都不含原本的日期。驗證：把 `readsSlots` 改成一律為真時 `swift test --filter EditedOccurrenceAddressTests` 在這個測試失敗。
- [x] 1.2 `Request` 帶 `seriesZone: TimeZone?`，`matches`、`miss`、`reason`、`notFoundDetail` 改吃 `Request`；非全天而沒有時區的系列不讀時段。驗證：1.1 通過，其餘既有的收集測試不改預期就通過。
- [x] 1.3 `listingRange(for:)` 回要求那一天的視窗前後各 366 天；測試帶標記 `spec-example: edited-occurrence-addressing / Listing around the requested day`：範圍的起訖、與主機時區及有無時區無關地小於三年、不含被移動場次的列出回找不到。驗證：該測試通過。
- [x] 1.4 span `future` 的訊息（requirement「Span future refusals say what the identifier takes」）：場次在要求那一天開始、原本的日期較早時，刪除說兩個日期之間的場次也會被刪，更新說寫入從原本的日期開始；沒有時區的系列的刪除訊息不寫日期並說明讀不到；更新訊息以 `DetachedOccurrenceSpan.ifThatIdIsRefused` 與 `laterOccurrencesLimits` 收尾。測試帶標記 `spec-example: edited-occurrence-addressing / Moved later with span future`，既有的 `Update with span future`、`Delete with span future` 兩個測試更新全文。驗證：三個測試通過，`swift test --filter DetachedOccurrenceSpanTests` 不改就通過（#416 的訊息逐位元組不變）。
- [x] 1.5 搬移列的日期用場次自己的時區印（requirement「Move row names event_ids and the start day」）：`Reading` 與 `Match` 帶 `timeZone`。測試帶標記 `spec-example: edited-occurrence-addressing / Own zone day in the move row`。驗證：該測試與既有的 `Move row` 測試通過。
- [x] 1.6 `echoed(_:seriesID:)` 只接受系列識別碼加 `/RID=` 加 ASCII 數字（requirement「Identifier echoed only in a known shape」），拿掉 sanitizer 條件；測試經 `reason` 走每一種不寫出的形狀（別的前綴、`/RID=` 後有非數字、第二個 `/RID=`、沒有數字）。驗證：`Identifier outside the allowed characters` 的測試與新的 builder 測試通過。
- [x] 1.7 `presence` 回三種結果、`exclusionReason` 產生 #534 自己的訊息（requirement「Idempotent retry and conflict detection」）。測試帶標記 `spec-example: recurrence-excluded-dates / Identifier of another shape on an excluded date` 與 `/ Conflict sentence for an edited occurrence`，既有三個排除日測試改比 `Presence`。驗證：這五個測試通過。
- [x] 1.8 找不到的訊息（requirement「Not-found answer prints the local day」）經 `notFoundDetail(for:)` 產生，沒有時區的系列用主機時區印日期。驗證：`Local day in the not-found text` 的測試通過。

## 2. 呼叫端

- [x] 2.1 `Sources/CheICalMCP/EventKit/EventKitManager.swift`：`occurrenceMissError` 建 `Request` 時把 `Self.occurrenceZone(of: series)` 原樣傳入，`editedOccurrences` 以 `listingRange` 列出；`Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift` 的 `seriesReadings(of:id:over:)` 把範圍交給 `seriesOccurrences`。驗證：`Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift` 的釘選（每個呼叫形式剛好一次、三個函式都沒有 `?? .current`、`dayReadings` 的視窗與述詞是開頭的兩句）通過。
- [x] 2.2 `createEvent` 的排除迴圈依 `presence` 的三種結果丟原本的衝突錯誤或新的 `EventKitError.exclusionEditedOccurrence`。驗證：釘選的整段迴圈剛好一次；`presence` 的函式本體不含任何讀時段的呼叫。
- [x] 2.3 釘選「搜尋不寫入」涵蓋 `seriesReadings` 與 `seriesOccurrences`，禁用清單加上 commit、undo 紀錄與各個 save helper；`SeriesListingKey` 不同範圍不相等、`SeriesListingMemo` 不把別的範圍的列出拿來用。驗證：`swift test --filter EditedOccurrenceAddressWiringTests` 通過。
- [x] 2.4 `Tests/CheICalMCPTests/EditedOccurrenceAddressHandlerTests.swift`：fake 記下 span 與 `occurrence_date`（搬移記每一列的日期），測試斷言它們；`text()` 遇到沒有文字的結果時讓測試失敗；檔頭寫明這些測試證明什麼、不證明什麼。驗證：`swift test --filter EditedOccurrenceAddressHandlerTests` 通過。

## 3. 文字與文件

- [x] 3.1 `Sources/CheICalMCP/Server.swift` 三個工具的說明與 `mcpb/manifest.json` 的摘要寫出拒絕何時適用（沒有未被單獨修改的場次在那一天開始時）；兩處 `excluded_occurrence_dates` 的說明寫出 `/RID=` 的條件與偵測不到的兩種情況。`Tests/CheICalMCPTests/ManifestParityTests.swift` 的測試移到 PR #415 的註解之上並更新片語（每個剛好一次）。驗證：`swift test --filter ManifestParityTests` 通過。
- [x] 3.2 `README.md`、`README_zh-TW.md`、`CHANGELOG.md` 寫出：拒絕何時適用、span `future` 從原本的日期開始、搬移列的日期用場次自己的時區、識別碼的形狀、三個找不到的限制（列不出來、超過 366 天、沒有時區的系列）、#534 自己的訊息與兩個偵測不到的情況、這次改動沒有在 Google 與 Exchange 上跑。驗證：文件釘選（每個片語在該文件剛好一次）通過。
- [x] 3.3 `.claude/rules/mcp-binary-version-testing.md` 的 #532 一節新增第 8 到 12 格（沒有時區的系列、開始很久的系列、被往後移的場次、有自己時區的場次、常駐 process 那一格只寫不做）與沒量過的清單。驗證：文件釘選通過。

## 4. 整套檢查

- [x] 4.1 mutation：每個新分支（`readsSlots`、列出範圍、自己的時區、衝突訊息的分支、識別碼的形狀與長度、共用常數）各拿掉一次，`swift test` 篩選後的測試要失敗；舊的表因為 Sources 改了而作廢，舊的分支重跑。驗證：每一列都是紅的。
- [x] 4.2 裝置：新 head 的 release build 用 Developer ID 簽章，只走 `--cli`，只在名稱含 `#532` 的拋棄式 iCloud 日曆上：第 8 到 11 格，以及更新、刪除、搬移、#534 重試各一格回歸；依 id 刪掉日曆，`probecount.py` 相隔一分鐘以上跑兩次，總數不變、`#532` 為 0。驗證：每格的答案與 release gate 寫的相同，量到的結果寫回 `.claude/rules/mcp-binary-version-testing.md` 與 `CHANGELOG.md`（寫出量的是哪一個 build）。實際（2026-11-14 更正）：依名稱的計數只在第一次執行後讀過一次（16:11:47，`h.py count`：`#532` 為 0）；`probecount.py` 在 16:11:52、16:16:28 與第二次執行後的 16:50:35、16:54:53 共跑四次，每次總數都是 72、各有 2 個名稱符合探測樣式的日曆，那四次沒有留下名稱。
- [x] 4.3 整套測試在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 各跑一次，都是 0 失敗；依（檔案、名稱）比對沒有測試函式被移除。驗證：三次的 `Executed N tests, with 0 failures` 與比對結果。實際（2026-11-14 更正）：對 `origin/main` 沒有測試函式被移除（新增 43 個）。對這個 PR 第一輪的 head `120810b0` 移除 1 個、新增 9 個：`EditedOccurrenceAddressWiringTests` 的 `testTheListingIsExposedWithoutAChange` 釘的是不帶範圍的列出呼叫，這一輪那個呼叫改成帶範圍，由 `testTheListingIsMadeOverTheRangeAroundTheRequestedDay` 取代。
