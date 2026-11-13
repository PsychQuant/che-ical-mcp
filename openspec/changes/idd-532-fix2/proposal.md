## Problem

PR #545 在第二輪 verify 之前還有兩處文字說得比量到的多或少，另有一個子句沒有量過（2026-11-13 的協調者裁決）：

- `update_event` 的工具說明寫 span `future` 的拒絕訊息會說「經那個識別碼的寫入從哪裡開始」，而只有一個場次時，訊息只在「被往後移、用它現在開始的那一天來指」的情況才說。
- 被往前移的單一場次：量到經它的識別碼做 span `future` 的寫入是從原本的日期開始，兩天之間的場次寫不到，訊息卻沒有說。
- 沒有時區的系列的 `delete_event` span `future` 訊息裡，「那個日期較早時，中間的場次也會被刪」是推出來的，沒有量過。量過之後發現另一件事：這種系列裡，經被修改場次的識別碼做 span `future` 刪除，之後的場次會被刪，那個場次本身卻留著，回應仍是 `deleted`（#549）。

## Root Cause

- 訊息只處理了「場次在要求的那一天開始、原本的日期較早」這一種移動。
- 沒有時區的系列的刪除訊息寫在量測之前。

## Proposed Solution

- 只有一個場次、而且它被移動過、原本的日期讀得到時，更新的 span `future` 訊息一律說寫入從原本的日期開始，並寫出量到的結果：往後移的，寫到了原本日期之後的場次；往前移的，兩天之間的場次沒有寫到；用原本那一天來指的，寫入不是從它現在開始的那一天起。原地修改的場次不說。
- 多個場次的更新訊息改成對原地修改的場次也成立的說法。
- 沒有時區的系列的刪除訊息照量到的寫：刪掉的是原本日期之後的場次、這個 server 讀不到那個日期、日期較早時要求那一天之前的場次也會被刪、那個場次本身會留下（#549）。
- `update_event` 的說明改成「對被移動過的場次，訊息會說寫入從哪裡開始」；`delete_event` 的說明加上沒有時區的系列量到的結果。
- README、CHANGELOG、release gate 跟著改；這個 PR 的每一個裝置格都在同一個 build 上重做，gate 與 CHANGELOG 只寫一個 build。

## Non-Goals

- #549 本身（沒有時區的系列裡刪除留下場次）：另一張 issue，這裡只在訊息裡照實寫。
- 沒有時區的系列的時段讀法（#539）。

## Success Criteria

- 純函式測試比對往前移、往後移、用原本那一天來指三種情況的更新訊息全文，以及原地修改與原本日期未知時沒有那一句。
- 沒有時區的系列的刪除訊息全文（單一與多個）有測試。
- 每個新分支各有一個 mutation 讓測試失敗；所有裝置格在新 head 的簽章 build 上結果與 release gate 寫的相同。
- 整套測試在三個時區都是 0 失敗，沒有測試被移除。

## Impact

- Affected specs: `edited-occurrence-addressing`（修改 requirement「Span future refusals say what the identifier takes」）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`
  - `Sources/CheICalMCP/Server.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift`
  - `Tests/CheICalMCPTests/ManifestParityTests.swift`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`
