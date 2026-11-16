## Problem

計時系列沒有時區時（`update_event` 帶 `clear_timezone` 之後）單獨修改的場次，識別碼的 `/RID=` 是它原本時間的牆上時間當成 UTC 寫下，不是時刻（PsychQuant/che-ical-mcp#539，2026-11-13 iCloud 量測）。這個 server 一律把計時場次的 `/RID=` 讀成時刻，在 `+08:00` 的主機上差 8 小時，所以：

- 整個系列刪除後 undo：記錄下來的修改場次對不上重建系列的任何場次，一致性檢查讓所有例外都不套用，系列從規則重建，所有修改遺失，單獨刪除的場次也回來（F1–F3、D2、L1、R2）。
- 之後再 undo 較早刪除的那個修改場次：#321 的檢查以錯的時刻比對，看不到重建系列在真正時間的場次，於是寫入第二個事件（MA）。

## Root Cause

`UndoPostState.ruleSlot` 只對全天系列把 `/RID=` 重新解讀為當地日期；計時場次一律當時刻。`/RID=` 在場次第一次被修改時就固定，系列之後換時區也不會改寫（R2：同一系列兩種都有），所以不能用「系列現在有沒有時區」決定怎麼讀。

## Proposed Solution

- 新的純型別 `SlotReadings`：計時 `/RID=` 有兩種讀法（時刻、以主機時區讀的牆上時間），全天或沒有 `/RID=` 的只有一種；`place(among:)` 只在恰好一種讀法是場次時採用它。
- 擷取：修改場次任一讀法在記錄視窗內就記錄，兩種讀法都留著。
- 還原：在重建系列的場次（視窗內，加上有需要時視窗外 14 小時的邊界）上放置每筆紀錄；放在視窗外的丟掉（交給規則），有一筆放不上去就整個不套用（all or nothing）。
- #321 的檢查：場次與持有者兩邊的所有讀法互相比對；只有同一個系列（或 undo 從它重建的系列）的場次算數。
- 刪除時的預告（計畫第 6 步）：整個系列刪除之前，把記下的修改場次放到規則從第一個場次展開的場次上；有放不上去的就在回應寫 `undo_note`，說 undo 預期只照規則重建。第一個場次讀不出來、規則展開器不跟、或整個呼叫的 undo 會被拒絕時不寫。
- 工具描述、manifest、README、CHANGELOG 與 release gate 一併更新。

## Non-Goals

- #503 檢查（`DeletedOccurrenceCheck.verdict`）怎麼讀浮動系列的修改場次（計畫第 4 步、mutant 10、裝置格 MB 與 R1）：協調者決定不在這裡做，提案寫在 #553 的留言。
- 三個小讀者（create-undo 的 `differsFromSeries`、#416 的 `originalDay`、#509 的規則結束檢查；計畫第 5 步、mutant 11）：協調者決定另開 issue 追蹤。
- 以 `occurrenceDate` 讀場次的原時間（Diagnosis 的 option 3）。
- 拒絕整個系列的刪除。
- `clear_timezone` 的行為（只改描述，#541）。
- 用 span `future` 刪除日期範圍時的試跑預告：同一次呼叫裡從較後場次切斷的列會讓整個 undo 拒絕，試跑分不出來，所以試跑不給預告（實際呼叫在沒有這種列時才給）。

## Success Criteria

- iCloud 上 F1、L1、U1、R2：undo 帶回兩個修改；D2：刪除的維持刪除、修改的回來；MA：第二次 undo 只寫一個事件；Z1、D1 不變。
- 一筆放不上去的紀錄讓整個例外都不套用。
- 刪除時有放不上去的修改場次，回應帶 `undo_note`；F1 的形狀（放得上去）沒有。
- 保有時區的系列在四種視窗邊界形狀上結果與以前相同。

## Impact

- Affected specs: `undo-history-discard`（新增一條 requirement）
- Affected code:
  - New: `Sources/CheICalMCP/EventKit/SlotReadings.swift`, `Tests/CheICalMCPTests/SlotReadingsTests.swift`, `Tests/CheICalMCPTests/FloatingSeriesExceptionsUndoTests.swift`
  - Modified: `Sources/CheICalMCP/EventKit/SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`, `Tests/CheICalMCPTests/OccurrenceSlotGuardTests.swift`, `Tests/CheICalMCPTests/SeriesExceptionsTests.swift`, `Tests/CheICalMCPTests/EventRangeQueryTests.swift`, `Tests/CheICalMCPTests/ManifestParityTests.swift`, `Tests/CheICalMCPTests/Helpers/FakeSeriesExceptionsStore.swift`
