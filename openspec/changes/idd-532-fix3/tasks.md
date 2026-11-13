<!--
ASSUMPTION: 沒有任何 task 帶 [P]，雖然 parallel_tasks 開著：每個 task 都以 build 或測試結束，
這台機器一次只跑一個 build（共用的 build 鎖），所以沒有可以平行的。
-->

## 1. 量測（裁決之前）

- [ ] 1.1 A1：沒有時區的系列裡原地修改一場、移動一場，給系列時區之後讀回 `/RID=` 與時區；用系列識別碼加原地修改場次的隔天、加它自己那一天各打一次。驗證：紀錄每個答案的全文。
- [ ] 1.2 A2：沒有時區的系列裡，經被往後移的場次的識別碼帶 span `future` 改標題。驗證：紀錄哪些場次改了，包含場次本身。
- [ ] 1.3 A3：一個常駐 stdio process 先讀過日曆，另一個 process 改了場次，再在常駐 process 上打三個呼叫。驗證：紀錄三個答案。

## 2. 程式與測試

- [ ] 2.1 `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`：時段不在系列時刻時不讀（紅燈在先），帶標記 `spec-example: edited-occurrence-addressing / Slot at another time of day than the series`；另一個測試確認一致的時段照舊讀。驗證：加 guard 之前第一個測試失敗、之後兩個都通過。
- [ ] 2.2 `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift` 的 `Request` 帶系列的開始時間，`slot(of:)` 只讀在系列時刻的時段；`Sources/CheICalMCP/EventKit/EventKitManager.swift` 的呼叫點交出 `series.startDate`，釘選跟著改。驗證：2.1 與 wiring 測試通過。
- [ ] 2.3 沒有時區的系列的 span `future` 更新訊息（單一與多個）照 A2 寫，帶標記 `spec-example: edited-occurrence-addressing / Update in a series with no time zone`。驗證：訊息全文的測試先失敗、後通過。
- [ ] 2.4 往前移的場次的 span `future` 刪除訊息加上量到的後果（單一與多個）；沒有時區的系列的刪除訊息把 #549 寫成已知缺陷。驗證：`Moved earlier with span future` 與 `Delete in a series with no time zone` 兩個測試先失敗、後通過。
- [ ] 2.5 測試：全天狀態與系列不同的被修改場次（`matches` 與 `presence`，兩個方向）；deny-list 拿掉在 Sources 裡不存在的四個拼法，並檢查每一項都出現；兩處示意用的斷言標明或拿掉。驗證：`swift test --filter EditedOccurrenceAddress` 通過。
- [ ] 2.6 `Sources/CheICalMCP/Server.swift` 的三個工具說明與 `mcpb/manifest.json` 的摘要：大約一年、時段不在系列時刻的場次、更新訊息在沒有時區的系列說什麼、往前移的刪除、#549 是已知缺陷、沒有場次的日子回找不到；`Tests/CheICalMCPTests/ManifestParityTests.swift` 的片語跟著改。驗證：`swift test --filter ManifestParityTests` 通過。
- [ ] 2.7 量到之後加的：有時區的系列裡，紀錄的時段不在系列時刻的場次，span `future` 更新訊息（單一與多個）說不要經它的識別碼用 span `future`，並寫出量到的結果（之後的場次移到另一天）；`Match` 帶這個旗標，帶標記 `spec-example: edited-occurrence-addressing / Span future through a slot off the series' time`。驗證：只加欄位時測試失敗、實作後通過。

## 3. 文件

- [ ] 3.1 `README.md`、`README_zh-TW.md`、`CHANGELOG.md`：上面各項、列出範圍的說法、stand-in 的兩個沒量過的情況、多個場次時搬移列印的時區。驗證：文件釘選（每個片語剛好一次）通過。
- [ ] 3.2 `.claude/rules/mcp-binary-version-testing.md` 的 #532 一節：第 2、8 格的新步驟、新增第 13 格、出版前要重做的格、沒量過的清單、「修正之前的 build」各句寫出是哪個 build 量的。驗證：文件釘選通過。
- [ ] 3.3 紀錄：gate 第 10 格的場次數照原始輸出更正；`CHANGELOG.md` 與 gate 寫出每一格是在哪個 build 上做的；已封存的 fix1 4.2、4.3 與 fix2 2.2 三句照紀錄更正；#549 加一則留言。驗證：每句對得上原始輸出或 git 紀錄。

## 4. 整套檢查

- [ ] 4.1 mutation：改過的 Sources 上整張表重跑，新分支各一個。驗證：每一列都是紅的。
- [ ] 4.2 裝置：新 head 的簽章 release build，只走 `--cli`（A3 用同一個 binary 的一個 stdio process），名稱含 `#532` 的拋棄式 iCloud 日曆：A1、A2、第 2、8、10 格、每個工具一格回歸與 #534 重試、A3；依 id 刪掉日曆，`probecount.py` 兩次並記下它印出的名稱。驗證：每格與 release gate 寫的相同。
- [ ] 4.3 整套測試在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 失敗；依（檔案、名稱）對 `f3bcf865` 與 `origin/main` 比對沒有測試被移除。驗證：三次的 `Executed N tests, with 0 failures`。
