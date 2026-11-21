## Problem

經一個場次自己的識別碼呼叫 `update_event` 或 `delete_event`（span `this` 或 `future`）時，`occurrence_date` 必須是那個場次開始的日子或它的原日（#416，`occurrenceDateMatches`）。全天系列的場次，原日從識別碼的 `/RID=` 讀出。在 UTC 以西的主機上，這個比對拒絕原日、接受前一天（#543：iCloud，`TZ=America/Los_Angeles`，原日 2026-12-28 被拒絕；前一天被接受是由程式推得，沒有量過）。拒絕時什麼都沒寫；接受時寫入仍落在識別碼指的那個場次。

## Root Cause

`occurrenceDateMatches` 用 `UndoPostState.originalSlot` 讀 `/RID=`，得到的是把數字當成 2001-01-01 UTC 起算秒數的瞬間。全天系列的 `/RID=` 是浮動日期，也就是那天 00:00 當成 UTC（裝置，2026-10-14）。全天比對取那個瞬間在本機時區的日子，UTC 以西時 00:00 UTC 還是前一晚。把全天 `/RID=` 讀成本機時區那天的函式早已存在（`UndoPostState.ruleSlot(..., isAllDay:)`，#285），同一個 commit（#416）加進來的這個比對沒有用它。

## Proposed Solution

- 新增純函式 `OccurrenceDateMatch.matches`，主機時區由參數傳入，同時交給 `UndoPostState.ruleSlot(zone:)` 與 `OccurrenceDay.startsOnRequestedDay(host:)`。場次的開始照舊以場次自己的全天旗標比對；原日以 `ruleSlot` 讀出，並以**系列**的全天旗標比對。
- 系列的全天旗標從系列物件讀（`seriesObject(ofOccurrence:)`，識別碼 `/RID=` 之前的部分）；讀不到（查不到、查找丟錯）時用場次自己的旗標。理由：`/RID=` 的數字在場次第一次被單獨修改時寫下，跟著當時的系列；計時系列中單獨改成全天的場次，它的 `/RID=` 是瞬間，拿場次的旗標去讀會在 UTC 以東把早上的原日讀成前一天。
- `occurrenceDateMatches` 改呼叫這個純函式。

## Non-Goals

- #546（主機時區在午夜跳過的日子）：日期解析與全天事件的讀出不在這裡改。
- #563（create-undo 的 `modified_occurrences` 計數也用原始 `/RID=` 瞬間）：另開 issue。
- `EventRangeQuery.covers`／`recordRemoval` 混用原始 `/RID=` 瞬間與本機 slot：全天系列一天只有一個場次，不會碰到，不改。
- 計時系列的 `/RID=`（#539 的兩種讀法）：屬於 PR #558，不在這裡改；計時的原日照舊以瞬間讀。

## Success Criteria

- 主機在 UTC−11、UTC−8、UTC、UTC+8、UTC+14 時，全天系列中被移到兩天後的場次，原日被接受，前一天與後一天被拒絕；顯示的那天照舊被接受。
- 計時系列中單獨改成全天的場次，以瞬間讀它的 `/RID=`，在 UTC+8 主機上早上 07:00 的原日被接受、前一天被拒絕。
- 系列物件讀不到時，以場次自己的旗標讀，結果與系列是全天時相同（全天場次）。
- 裝置（iCloud、`--cli`、簽章的 release build、名稱含 `#543` 的拋棄式日曆）：`TZ=America/Los_Angeles` 與主機時區下，原日被接受、前一天被拒絕。

## Capabilities

### New Capabilities

- `occurrence-date-own-identifier`：經場次自己的識別碼帶 `occurrence_date` 時，哪些日子算那個場次的日子。

### Modified Capabilities

(none)

## Impact

- Affected specs: 新 capability `occurrence-date-own-identifier`
- Affected code: `Sources/CheICalMCP/EventKit/OccurrenceDateMatch.swift`（新）、`Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift`（`occurrenceDateMatches`）、`Tests/CheICalMCPTests/OccurrenceDateMatchTests.swift`（新）、`Tests/CheICalMCPTests/OccurrenceDateMatchWiringTests.swift`（新）、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`（release gate）
