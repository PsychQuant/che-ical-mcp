## Problem

PR #545（#532、#534、#535）的第三輪 verify：整套測試在三個時區都是 0 失敗，第二輪的兩個 MEDIUM 已修，Codex 沒有擋 merge 的發現；但這一輪加的「時段要在系列時刻才讀」本身又回了錯的答案。三輪下來，每一個「訊息點名了另一天的場次」或「照訊息做會刪掉沒被告知的場次」的發現，都出自同一件事：從場次的 `/RID=` 讀出「原本的那一天」。

- 第一輪：沒有時區的系列，`/RID=` 是牆上時間讀成 UTC（#539）。
- 第二輪：場次被修改之後才有時區的系列，`/RID=` 不變。
- 第三輪：拿來比對的系列時刻取自 `series.startDate`，第一場被單獨移動時它是移動後的時刻（發現 1、3、5：正確的時段被丟掉、還被標成不在系列時刻）；刪除訊息因此少了「要求那一天之前的場次也會被刪」的警告（發現 2、4）；全天系列完全沒有檢查（發現 7）。

以場次開始的那一天來比對的部分，自第一輪修正時區與 id 形狀之後就沒有再出現這類發現。

## Root Cause

「原本的那一天」要從 store 記下的時段讀出來，而那個時段在不同的系列形狀下有不同的意思（時刻、牆上時間讀成 UTC、全天的日期），每一種都要量過 store 的行為才知道。這些行為（全天轉換之後的 `/RID=`、日光節約時間跳過的那一小時、常駐 store 裡的 `occurrenceDate`）都沒有量過。

## Proposed Solution

協調者 2026-11-16 的預設裁決（記在 #532，維護者可以改）：PR 只保留不讀時段的那一半。

- 比對只看開始的那一天：查找落空時，這個系列裡被單獨修改過、在要求的那一天開始的場次（當天的事件、id 是系列 id 加 `/RID=`）得到帶它 id 的拒絕。被移到別天的場次，用系列 id 加它被移走的那一天，回找不到，與 `main` 相同（帶 #535 的日期文字）；`list_events` 以它自己的 id 列出它。
- 拿掉：`Kind.originallyThatDay`、`Match.originalDay`、`moved`、`Match.slotOffSeriesTime`、時刻檢查與 `Request.seriesStart`、`matches` 讀時段的部分、查找落空時對系列的列出（`seriesReadings(of:id:over:)` 與它的範圍）。量過的來源（iCloud；Google 經 EventKit，#320）裡，每個被單獨修改的場次 id 都是系列 id 加 `/RID=` 加數字，第一場被刪掉、由較後場次代表的系列也是（gate 第 7 格），所以當天的列舉找得到每個在那一天開始的場次；`Reading` 只剩 id、全天狀態、開始與時區。
- 留著：回顯規則（系列 id 加 `/RID=` 加數字）、搬移列用場次自己時區的那一天（R6）、#534 的排除檢查（本來就只看開始）、#535 的找不到日期、處理沒有時區的系列、handler 測試與其他修正、訊息是受信任的、不寫 stderr。
- 之後只有回顯的形狀檢查會看 `/RID=` 後面的數字（檢查是不是數字，不讀成日期）。
- 訊息：不印、也不暗示原本的日期，不說場次「原本在那一天」。span `future`（update 與 delete、單一與多個）說：經那個 id 的呼叫從那個場次原本的日期開始，這個 server 讀不到那個日期；日期較早時，要求那一天之前的場次也會被寫到（刪掉），較晚時，要求那一天到那個日期之間的場次寫不到。附上量過的（不寫日期）。每一則都加 #550 那一句：store 把那個場次記在系列以外的時刻時，經它的 id 的 span `future` 更新把之後的場次移到了另一天；update 說 span `this` 是測過的路，delete 寫 #550 量到的刪除結果（不照抄 update 的說法，因為刪除量到的不是那樣）。#549 那一句只留在沒有時區的系列的刪除訊息。
- 工具說明、manifest 摘要、README、CHANGELOG、release gate 跟著改；拿掉「被移走的場次會被拒絕」「大約一年」「時刻檢查」「off-time 標記」的說法。第三輪紀錄類發現 13、14、16、18、21 一併處理。

## Non-Goals

- 讀出被單獨修改過場次的原本時段（#539、#553、#550 各自的範圍）。被移走的場次交還給它們。
- #549、#548、#550 本身的修正。
- session MCP 上的第 12 格（出版前的 gate 項目）。
- 把 XCTest 改成 Swift Testing。

## Success Criteria

- 純函式測試：被移到別天的場次，用它被移走的那一天回找不到（update、delete、搬移列，#535 的文字）；任何訊息都沒有原本的日期、沒有 "was on that day"；span `future` 的訊息在有時區、沒有時區、多個場次三種形式都對；#550 那一句；`/RID=` 的數字指向別天時，不會在那一天配對（比對不讀時段）。
- 每個留下來的分支與訊息各有一個 mutation 讓測試失敗，存活的逐一說明。
- 新簽章的 build 上：每個工具的回歸格、被移走的場次用系列 id 加原本那一天回找不到、沒有時區的系列的訊息、#534 重試、stdio 格。
- 整套測試在三個時區都是 0 失敗；被移除或改寫的測試逐一列出原因。

## Impact

- Affected specs: `edited-occurrence-addressing`（修改六個 requirement：Series identifier and day do not address an edited occurrence、Several edited occurrences are all listed、Span future refusals say what the identifier takes、Move row names event_ids and the start day、Identifier echoed only in a known shape、Not-found answer prints the local day）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`
  - `Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift`
  - `Sources/CheICalMCP/Server.swift`
  - `mcpb/manifest.json`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressHandlerTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift`
  - `Tests/CheICalMCPTests/ManifestParityTests.swift`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`
