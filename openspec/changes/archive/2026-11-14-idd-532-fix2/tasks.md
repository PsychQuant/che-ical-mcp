<!--
ASSUMPTION: 沒有任何 task 帶 [P]，雖然 parallel_tasks 開著：每個 task 都以 build 或測試結束，
這台機器一次只跑一個 build（共用的 build 鎖），所以沒有可以平行的。
-->

## 1. 訊息與測試

- [x] 1.1 `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`：往前移的單一場次的更新與刪除訊息全文，帶標記 `spec-example: edited-occurrence-addressing / Moved earlier with span future`；被移動過的場次各有一句、原地修改與原本日期未知的沒有。驗證：`swift test --filter EditedOccurrenceAddressTests` 通過，拿掉往前移的分支時失敗。
- [x] 1.2 `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift` 的更新訊息對每個被移動過的場次說寫入從哪裡開始（requirement「Span future refusals say what the identifier takes」）；多個場次的說法對原地修改的場次也成立。驗證：1.1 與既有的 `Update with span future`、`Moved later with span future`、`Two for one day` 測試通過。
- [x] 1.3 沒有時區的系列的刪除訊息照量到的寫（#549），單一與多個；測試帶標記 `spec-example: edited-occurrence-addressing / Delete in a series with no time zone`。驗證：`testATimedSeriesWithNoTimeZoneIsMatchedByStartOnly` 通過。
- [x] 1.4 `Sources/CheICalMCP/Server.swift` 的 `update_event` 與 `delete_event` 說明；`Tests/CheICalMCPTests/ManifestParityTests.swift` 的片語跟著改。驗證：`swift test --filter ManifestParityTests` 通過。

## 2. 文件

- [x] 2.1 `README.md`、`README_zh-TW.md`、`CHANGELOG.md` 寫出兩個方向的量測與 #549。驗證：文件釘選（每個片語剛好一次）通過。
- [x] 2.2 `.claude/rules/mcp-binary-version-testing.md` 的 #532 一節：第 8、10 格的文字與新量到的結果；所有格在同一個 build 上重做之後，把「哪幾格在哪個 build」的分法拿掉，`CHANGELOG.md` 也只寫一個 build。驗證：文件釘選通過。實際（2026-11-14 更正）：寫成同一個 build（`d4bdfebf`）的是第 1 到 11 格；第 11 格補充的時區讀取仍記為 `022f2b92` 的 build，沒有重做。

## 3. 整套檢查

- [x] 3.1 mutation：改過的 Sources 上整張表重跑，新分支（往前移、用原本那一天來指、原地修改不說、沒有時區的刪除訊息）各一個。驗證：每一列都是紅的。實際：commit `d4bdfebf` 上 61 列，每一列都 build 成功、測試失敗。
- [x] 3.2 裝置：新 head 的簽章 release build，只走 `--cli`，名稱含 `#532` 的拋棄式 iCloud 日曆：第一輪的新格（沒有時區的系列、開始很久的系列、有自己時區的場次、被往後移與往前移的場次）、每個工具一格回歸與 #534 重試、gate 第 7 格（全天系列、第一場被刪的系列）、沒有時區的系列的刪除；依 id 刪掉日曆，`probecount.py` 兩次。驗證：每格與 release gate 寫的相同。實際：commit `d4bdfebf` 的簽章 release build，gate 第 1 到 11 格（第 12 格沒有做）；用原本那一天來指的 span `future` 更新訊息與多個場次的 span `future` 訊息沒有裝置格，只有純函式測試；日曆依 id 刪掉後 `probecount.py` 兩次，總數都是 72（與執行前相同），各有 2 個名稱符合探測樣式的日曆，那兩次沒有留下名稱；隔天第三次計數（仍是 72）由協調者讀過，沒有名稱含 `#532` 的日曆。
- [x] 3.3 整套測試在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 失敗；依（檔案、名稱）比對沒有測試被移除。驗證：三次的 `Executed N tests, with 0 failures`。實際：commit `10f9aa43` 上三個時區都是 `Executed 3235 tests, with 0 failures`；對 `732b5b9c` 與 `origin/main` 都沒有測試被移除，對 `732b5b9c` 新增 1 個。
