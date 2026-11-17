## Problem

delete 的 undo 不是把被刪的項目還原回去，而是從快照寫一個新的項目，新項目有新的識別碼（PsychQuant/che-ical-mcp#538，2026-11-13 在 iCloud 量到：一次性事件與提醒事項都換；系列在 #335 量過）。undo history 以識別碼指認項目，較舊的紀錄（create、update、move、提醒事項的 create／update／completion）仍指著舊識別碼，所以：

- `create_event` → `delete_event` → `undo` → `undo`：第二次 undo 回「not found under its recorded identifier」，紀錄留在最上面，底下的紀錄全部被擋住，只能用 `discard_id` 放棄。
- 提醒事項同樣如此，而且提醒事項 delete 的 undo 回應不給新識別碼。

## Root Cause

delete 的紀錄（`.deleteEvent`、`.deleteReminder`）沒有記被刪項目的識別碼（系列只在快照的 `seriesIdentity` 裡有），delete 的 undo 寫出新項目後也沒有呼叫改寫。PR #469 與 #552 的改寫機制（`CalendarUndoManager.replaceEventIdentifier`）只用在 move 與換日曆；提醒事項沒有對應的改寫。

## Proposed Solution

- `.deleteEvent` 與 `.deleteReminder` 的 case 加上 `id`（被刪項目的識別碼；系列是系列本身、不帶 `/RID=` 的識別碼），沒有預設值，漏記的紀錄點編譯不過。
- delete 的 undo 重建成功之後，依封閉清單決定是否把較舊的紀錄改寫到新識別碼（`DeleteUndoFollow.identifierToFollow`）：一次性事件跟隨；整個系列跟隨，除非這次還原把單獨改過的場次寫回成獨立事件（`oneOffs` 大於 0）；場次的紀錄、split move、move 退回 copy and delete 的來源都不跟隨；提醒事項在存檔回來之後跟隨。失敗、回滾、slot 已被佔住的路徑都不改寫。batch 逐一成員處理。
- 新增提醒事項的改寫（`UndoOperation.replacingReminderIdentifier`、`CalendarUndoManager.replaceReminderIdentifier`），涵蓋 `createReminder`、`updateReminder`、`completeReminder`、`completeRecurringReminder`；事件與提醒事項的識別碼分開改寫。
- 系列不跟隨時，delete 的 undo 在有較舊紀錄指著該系列時加一句說明；那些紀錄帶一個旗標（`UndoRecord.seriesNotFollowed`），之後 undo 找不到時回專用的拒絕文字，取代一般的 not found。旗標跟著紀錄走，紀錄被丟棄時旗標一起消失。
- 提醒事項 delete 的 undo 回應加上 ` (new ID: <id>)`。
- `undo` 描述、manifest 摘要、README、CHANGELOG 與 release gate 一併更新。

## Non-Goals

- move 退回 copy and delete 時的來源（#466 在裝置上造不出這個情況）。
- `update_reminder` 跨帳號換清單與它的 undo（#536，之後會用這裡加的提醒事項改寫）。
- #321 slot guard 讀的系列識別碼（#537）、changed-after 拒絕的歸因措辭（#540）、浮動系列從規則重建（#539）。
- 不在 `undo_history` 上標記無法跟隨的紀錄，也不在 `undo` 回應新增結構化的新識別碼欄位。
- 不採用「丟棄指著舊識別碼的紀錄」（Diagnosis 的 Option B）：會在沒有詢問的情況下讓使用者失去 create／update 的 undo。

## Success Criteria

- `create_event` → `delete_event` → `undo` → `undo`：第二次 undo 刪掉重建的事件，不是 not found。
- `create_event` → 改標題 → `delete_event` → `undo` ×3：第二次還原標題，第三次刪掉事件。
- `create_reminder` → `delete_reminder` → `undo` → `undo`：第一次回應帶新識別碼，第二次刪掉重建的提醒事項。
- 系列 create → 整個刪除 → `undo` → `undo`：第二次刪掉重建的系列。
- 系列有一個單獨改過的場次時：delete 的 undo 結尾有說明句，之後的 undo 回專用拒絕文字、什麼都沒寫、紀錄保留；`discard_id` 丟棄後不再出現這段文字。
- 場次的 delete 的 undo 不改寫任何紀錄；delete 紀錄自己持有的識別碼從不被改寫。

## Impact

- Affected specs: `undo-history-discard`（新增一條 requirement，修改 #484 那條的第一句）
- Affected code:
  - Modified: `Sources/CheICalMCP/EventKit/UndoManager.swift`, `Sources/CheICalMCP/EventKit/DeleteUndo.swift`, `Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift`, `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/EventKit/UndoBatchRestore.swift`, `Sources/CheICalMCP/EventKit/UndoGuardErrors.swift`, `Sources/CheICalMCP/ReminderCompletion.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`, 以及以 `.deleteEvent(`／`.deleteReminder(` 建立或比對紀錄的測試檔（機械性加上 `id`）
  - New: `Sources/CheICalMCP/EventKit/DeleteUndoFollow.swift`, `Tests/CheICalMCPTests/DeleteUndoFollowTests.swift`, `Tests/CheICalMCPTests/DeleteUndoFollowWiringTests.swift`, `Tests/CheICalMCPTests/DeleteUndoFollowHandlerTests.swift`, `Tests/CheICalMCPTests/DeleteUndoFollowHistoryTests.swift`
  - （2026-11-17 更正，idd-538-fix1：原本列了 `UndoPostStateGuard.swift`，實際沒有改；新增的測試檔漏列 `DeleteUndoFollowHandlerTests` 與 `DeleteUndoFollowHistoryTests`。）
