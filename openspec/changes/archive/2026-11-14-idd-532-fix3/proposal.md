## Problem

PR #545（#532、#534、#535）的第二輪 verify 回了 3 個 MEDIUM、13 個 LOW、28 個 INFO，這一輪不 merge。協調者的裁決是 S1 到 S7（2026-11-14），先量三件事再決定程式怎麼改：

- **場次被修改之後才有時區的系列（S1，量到會重現，擋 merge）**：系列沒有時區時被單獨修改的場次，`/RID=` 是牆上時間讀成 UTC（#539）。在 iCloud 上量到：系列之後有了時區，這個數字不變。`EditedOccurrenceAddress` 對有時區的系列把它當成時刻讀，所以在臺北的主機上，用系列識別碼加被原地修改場次的隔天（那天沒有場次），回的是點名那個場次的拒絕。這是第一輪 R1 的同一類錯誤。量測另外發現兩件事：現在的 build 給不了這種系列時區（#503 的檢查拒絕），要舊版或別的 app 才走得到；給了時區之後 store 會把規則在那一天的場次再帶回來。
- **沒有時區的系列的 span `future` 更新訊息（S2）**：訊息沒有說經那個識別碼的寫入從哪裡開始，而刪除訊息有說。量到：經被往後移的場次的識別碼改標題，寫到了原本日期之後的場次（要求那一天之前的那一場也是）與那個場次本身。
- **往前移的場次的刪除訊息（S3）**：訊息只說從原本的日期起刪，量到的是那個場次本身也被刪、兩天之間的場次留著。
- **#549（S4）**：訊息把它寫成量到的行為，沒有說是已知缺陷，也沒有說那個呼叫回 `deleted`；README 說得比訊息多。
- **用詞與限制（S5）**、**測試（S6）**、**紀錄（S7）**：列出範圍是 366 天以秒計；manifest 摘要可以讀成每個沒有場次的日子都會被拒絕；全天狀態與系列不同的被修改場次沒有測試；deny-list 有四個在 Sources 裡不存在的拼法；gate 與已封存的 task 有幾句說得比紀錄多。

## Root Cause

- 讀時段的條件只看系列現在有沒有時區，沒有檢查那個時段是不是這個系列的規則會給的時刻。
- 沒有時區的系列的更新訊息寫在量測之前，照「原本日期讀不到就什麼都不說」處理。
- 往前移的刪除沿用「原本日期較晚就不加句子」，沒有對照第 2 格量到的結果。

## Proposed Solution

- 有時區的非全天系列裡，從 `/RID=`（或 `occurrenceDate`）讀到的時段，只有在它於系列時區的時刻等於系列開始時間於該時區的時刻時才讀；不一致時不讀：不會以「原本在那一天」被找到、沒有原本的日期、不算被移動，與沒有時區的系列得到的結果相同。系列的開始時間由呼叫點交給 `Request`。代價（寫成限制）：場次被修改之後整個系列改到另一個時刻的系列、時段落在日光節約時間跳過的那一小時的場次，也失去以時段為準的答案。全天系列不變。
- 沒有時區的系列的 span `future` 更新訊息（單一與多個）說：寫入從該場次原本的日期開始、這個 server 讀不到那個日期、日期較早時要求那一天之前的場次也會被寫到，以及量到的結果。
- 往前移的場次的 span `future` 刪除訊息加上量到的後果；多個場次的說法也加。
- 沒有時區的系列的刪除訊息把 #549 寫成已知缺陷：那個呼叫回 `deleted`，那個場次卻留著。
- 工具說明、manifest 摘要、README、CHANGELOG、release gate 跟著改；gate 新增第 13 格（場次被修改之後才有時區的系列），第 8 格補上 span `future` 更新那一步。
- 測試：全天狀態與系列不同的被修改場次（兩個方向）、deny-list 每一項都要在 Sources 裡出現、兩處只是示意的斷言標明或拿掉。

## Non-Goals

- 讀出沒有時區的系列的原本時段（#539）。
- #549、#548 本身。
- #503 的檢查把沒有時區的系列裡每個被修改的場次都當成規則沒有的場次（另開 issue）。
- session MCP 上的第 12 格（出版前的 gate 項目）。

## Success Criteria

- 紅燈在先的純函式測試：臺北、每週一 20:00 的系列，`/RID=` 是 20:00 讀成 UTC；要求週二沒有結果，要求週一時沒有原本的日期、沒有被移動的句子。另一個測試確認一致的時段照舊讀得到（跨日光節約時間、任何主機時區）。
- 每個新分支各有一個 mutation 讓測試失敗（guard 拿掉、反過來、用錯時區；沒有時區的更新句子；往前移的刪除子句；#549 的用詞）。
- 新簽章的 build 上：第 13 格的隔天回找不到；第 8 格的更新訊息與量到的結果相符；第 2、10 格的訊息與量到的結果相符。
- 整套測試在三個時區都是 0 失敗，沒有測試被移除。

## Impact

- Affected specs: `edited-occurrence-addressing`（修改四個 requirement：Series identifier and day do not address an edited occurrence、Span future refusals say what the identifier takes、Move row names event_ids and the start day、Not-found answer prints the local day）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`
  - `Sources/CheICalMCP/Server.swift`
  - `mcpb/manifest.json`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressHandlerTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift`
  - `Tests/CheICalMCPTests/ManifestParityTests.swift`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`
