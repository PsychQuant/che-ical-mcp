## Problem

PR #565（#543）第一輪 verify（Claude 席 V1–V21、Codex 席 X1–X6）：程式在一些形狀上比 `main` 寬，也就是接受了 `main` 會拒絕的錯日子。

- **系列的旗標是現在的，`/RID=` 的數字跟著第一次修改時的系列**（V1、V2、V3、V12、V15、X1）：
  - 系列物件讀不到時，head 退回場次自己的旗標。計時系列中改成全天的場次（`/RID=` 是 07:00 Asia/Taipei 的瞬間 23:00 UTC）會被當浮動日期讀，結果接受 12-27、拒絕 12-28，而 `main` 答對。
  - 系列在修改之後改成全天（#428 (h) 經第一場自己的識別碼帶 `all_day: true`，或 Calendar.app）也是同一個結果。
- **計時讀法的比對不是 `main` 的**（X2、V14、V18）：head 拿系列旗標比對，全天場次帶非 nil 時區時，答案和 `main` 不同。
- **浮動日期經本機時區的瞬間比對**（X3）：主機跳過的日子（Pacific/Apia 2011-12-30）會被讀成隔天。
- **只有外部識別碼帶 `/RID=`**（V4、V21）：系列查不到，退回場次旗標。

## Root Cause

數字是日期還是瞬間，看的是場次第一次被單獨修改時的系列（#539 cell R2）。head 拿現在的旗標去判斷，所以判斷不出來的形狀也當成判斷得出來。

## Proposed Solution

- `OccurrenceDateMatch.answer` 回 `matches`／`differs`／`undetermined`。`/RID=` 的讀法（`reading`）如下：
  - 數字不是某天 00:00 UTC：照 `main`（浮動日期一定是 00:00 UTC）。
  - 系列讀得到且系列與場次都是全天：浮動日期，以 UTC 年月日直接比對要求的那天（X3）。
  - 系列讀得到且兩者都是計時：照 `main`。
  - 其餘：兩種讀法都給那天才接受；只有一種給時是 `undetermined`，拒絕理由另寫。
- 瞬間讀法的比對就是 `main` 的（場次自己的旗標與時區，X2）。
- 接線不再退回場次旗標，讀不到時傳 nil。不以外部識別碼查系列（V4：EventKit 以識別碼查找，外部識別碼是 UID，沒有量過）。
- 拒絕理由：`undetermined` 時說「可能是原日但分不出來」，並指出可以用顯示的那天，或不帶 `occurrence_date`。不提系列識別碼：#532 對編輯過的場次只回它的識別碼，不會寫到它。
- 以格子表（`OccurrenceDateMatchCellTests`）比對每一格和 `main`、和寫入方式所對應的正確日子，並列出例外。

## Non-Goals

- 計時系列沒有時區時，數字是牆上時間（#539）：這個檢查照 `main` 以瞬間讀，問題留在 #569（新開），不交給 PR #558。
- 以外部識別碼查系列。
- 系列轉換時 store 是否重寫 `/RID=`：沒有量。
- 封存的 `2026-11-22-idd-543-allday-occurrence-date` 不改（封存保護）。它的 V9、V11、X5 由這個 change 的 delta spec 與本 proposal 更正：
  - `ruleSlot(eventIdentifier:…)` 是和這個比對同一個 #416 commit（`7d435615`）加進來的，裡面的全天讀法來自 #285。原 proposal 說它「早已存在」，是錯的。

## Success Criteria

- `OccurrenceDateMatchCellTests` 的每一格都屬於下列之一，例外集合與 spec 的 scenario 一致：
  - 和 `main` 相同；
  - 修好 #543；
  - 在 `main` 接受錯日子的地方拒絕。
- V3 的形狀與 X3 的形狀先對 head 的邏輯紅，再綠。
- 完整 `swift test` 在三個時區都是 0 failures。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `occurrence-date-own-identifier`：原日的讀法只到識別碼看得出來為止。

## Impact

- Affected specs: `occurrence-date-own-identifier`
- Affected code:
  - `Sources/CheICalMCP/EventKit/OccurrenceDateMatch.swift`
  - `Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift`
  - `Sources/CheICalMCP/EventKit/DetachedOccurrenceSpan.swift`（拒絕理由）
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`（兩個拒絕點）
  - `Tests/CheICalMCPTests/OccurrenceDateMatchTests.swift`
  - `Tests/CheICalMCPTests/OccurrenceDateMatchCellTests.swift`（新）
  - `Tests/CheICalMCPTests/OccurrenceDateMatchWiringTests.swift`
  - `Tests/CheICalMCPTests/DetachedOccurrenceSpanTests.swift`
  - `CHANGELOG.md`
  - `.claude/rules/mcp-binary-version-testing.md`
