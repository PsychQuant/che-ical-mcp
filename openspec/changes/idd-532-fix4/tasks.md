<!--
ASSUMPTION: 沒有任何 task 帶 [P]：每個 task 都以 build 或測試結束，這台機器一次只跑一個 build（共用的 build 鎖）。
-->

## 1. 程式與測試

- [ ] 1.1 Requirement「Series identifier and day do not address an edited occurrence」與「Several edited occurrences are all listed」：`Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`：`matches(onDay:for:)` 只讀當天的事件、只看開始的那一天；拿掉 `Kind`、`originalDay`、`slotOffSeriesTime`、`seriesStart`、`readsSlots`、`listingRange`；`Reading` 只剩 id、全天狀態、開始與時區。驗證：`swift build` 通過，`EditedOccurrenceAddressWiringTests.testTheSearchReadsNoSlotAndListsNoSeries` 通過。
- [ ] 1.2 `Sources/CheICalMCP/EventKit/EventKitManager.swift` 的 `editedOccurrences(for:)` 不再列出系列，`occurrenceMissError` 不再交出系列開始；`Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift` 的 `seriesReadings` 拿掉。驗證：wiring 測試通過，`FirstRemainingOccurrence.swift` 與 `origin/main` 相同。
- [ ] 1.3 Requirement「Span future refusals say what the identifier takes」與「Move row names event_ids and the start day」，訊息：開頭改成 "An occurrence of this series that starts on <day> was edited on its own"；span `future` 的 update 與 delete（單一與多個）說兩個方向、不寫日期、附量過的、加 #550 那一句；#549 只留在沒有時區的系列的刪除訊息。驗證：`EditedOccurrenceAddressTests` 的訊息全文測試通過。
- [ ] 1.4 Requirement「Identifier echoed only in a known shape」與「Not-found answer prints the local day」的測試照舊，加上：被移到別天的場次只用開始的那一天找到；`/RID=` 指向別天時不在那一天配對；沒有任何訊息有原本的日期；#550 那一句；被移除與改寫的測試在報告裡逐一列出原因。驗證：`swift test --filter EditedOccurrenceAddress` 通過。
- [ ] 1.5 `Sources/CheICalMCP/Server.swift` 的三個工具說明與 `mcpb/manifest.json` 的摘要跟著改；`Tests/CheICalMCPTests/ManifestParityTests.swift` 的片語跟著改。驗證：`swift test --filter ManifestParityTests` 通過。

## 2. 文件

- [ ] 2.1 `README.md`、`README_zh-TW.md`、`CHANGELOG.md`：拿掉被移走的場次會被拒絕、大約一年、時刻檢查、off-time 標記的說法；寫出被移走的場次回找不到、`list_events` 以它自己的 id 列出它；span `future` 的新說法。驗證：文件釘選（每個片語剛好一次）通過。
- [ ] 2.2 `.claude/rules/mcp-binary-version-testing.md` 的 #532 一節：各格的預期照縮小之後的行為重寫（第 4、9、13 格的原本那一天改成找不到）；第三輪紀錄類發現 13、14、16、18、21。驗證：文件釘選通過，每句對得上原始輸出或 git 紀錄。

## 3. 整套檢查

- [ ] 3.1 mutation：新的 Sources 上，每個留下的分支與訊息各一個。驗證：每一列都是紅的，存活的逐一說明。
- [ ] 3.2 裝置：新 head 的簽章 release build，只走 `--cli`（stdio 格用同一個 binary 的一個常駐 stdio process），名稱含 `#532` 的拋棄式 iCloud 日曆：每個工具的回歸格、被移走的場次、沒有時區的系列的訊息、#534 重試、stdio 格；依 id 刪掉日曆，`probecount.py` 隔一分鐘兩次、至少一小時後再一次。驗證：每格與 release gate 寫的相同。
- [ ] 3.3 整套測試在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 失敗；依（檔案、名稱）對 `e0a7b6fb` 與 `origin/main` 比對被移除的測試。驗證：三次的 `Executed N tests, with 0 failures`。
