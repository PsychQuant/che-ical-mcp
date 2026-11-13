## Problem

在 Google 帳號上，`update_event` 帶 `calendar_name` 把事件換到同帳號的另一個日曆時，事件會拿到新的識別碼（PsychQuant/che-ical-mcp#484，2026-11-13 量測：一次性事件 4 次都換、整個系列 1 次；跨帳號則在任何來源都會換，#226）。undo history 以識別碼指認事件，較舊的紀錄仍指著舊識別碼，所以：

- 換日曆之後，較舊的 create／update 紀錄再 undo 會回「not found under its recorded identifier」，紀錄留在最上面，底下的紀錄全部被擋住。
- 那次換日曆的 undo 把事件搬回原日曆時又換一次識別碼，回應沒有回報新識別碼，較舊的紀錄同樣失聯。帶 `keep_later_edits` 的 undo 也一樣。

`move_events_batch` 自 PR #469（#435）起已經處理同一件事：in-place 搬移與它的 undo 都會把較舊的紀錄改寫到新識別碼。

## Root Cause

`EventKitManager.updateEvent` 存檔後有讀新的識別碼，但只用在這次 update 自己的紀錄與回應，沒有呼叫 `CalendarUndoManager.replaceEventIdentifier`。`.updateEvent` 的 undo 臂與 `keep_later_edits` 的事件臂存檔後完全不讀識別碼。改寫機制本身是通用的，缺的是三個呼叫點。

## Proposed Solution

- `update_event` 存檔後，五個條件全部成立時把較舊的紀錄（undo 與 redo 兩個 stack）改寫到新識別碼：這次呼叫換了日曆；寫的是整個事件（事件不重複，或 span `all`）；不是經 stand-in 解析；識別碼不是場次自己的；存檔後的識別碼與傳入的不同（以系列部分比較）且不為空。這是封閉清單，其他原因造成的新識別碼（例如 span `future` 的分裂）不改寫。
- 一次性事件的 update-undo 與帶 `keep_later_edits` 的 undo，存檔後比對紀錄的識別碼與事件的識別碼；不同時改寫較舊的紀錄，並在回應結尾加上 ` (new ID: <id>)`。
- 整個系列只需要正向那一步：系列換日曆的 undo 是 marker，什麼都不寫。
- 工具描述、manifest 摘要、README、CHANGELOG 與 release gate 的 (j) 一併更新。

ASSUMPTION: proposal 與 `tasks.md` 照本 repo 的 Spectra locale 用繁體中文，spec 照規定用英文；貼到公開 issue 的 Spec tasks 留言與 Implementation Complete 的 checklist 以英文逐項對應 `tasks.md` 的編號。

## Non-Goals

- 提醒事項（`update_reminder` 跨帳號換清單）：#536。
- #321 slot guard 讀的系列識別碼：#537。
- delete 的 undo 重建出新識別碼：#538。
- 系列分裂、或剩下的部分拿到新識別碼時不跟隨（協調者 2026-11-13 的預設，與 #377 一致）。
- changed-after 拒絕訊息把變更歸給另一個 app 或伺服器的措辭：#540。
- `undo` 回應不新增結構化欄位；新識別碼只在 `message` 裡，與 move 的 undo 相同。
- 不採用「每次存檔後統一比對識別碼」的通用 hook：它必須分辨改名與分裂，而且要改動所有既有事件的存檔點。
- 不採用「undo 時用別的 key 找事件」：Google 上 iCalendar UID 也會跟著換，沒有穩定的 key。

## Success Criteria

- Google 帳號上 `create_event` → `update_event`（換日曆）→ `undo` → `undo`：第一次 undo 的回應以新識別碼結尾，第二次 undo 刪掉事件，不是 not found。
- `create_event` → 改標題 → 換日曆 → `undo` ×3：第二次還原標題，第三次刪掉事件。
- 換日曆後丟棄那筆紀錄再 `undo`：create 紀錄找得到事件，並以 `calendar` 被 #236 的比對拒絕（與 move 相同），不是 not found。
- 識別碼沒變的來源（iCloud 同帳號）：行為與回應文字逐字不變。
- span `future` 的寫入不觸發改寫。

## Impact

- Affected specs: `undo-history-discard`（新增一條 requirement）
- Affected code:
  - Modified: `Sources/CheICalMCP/EventKit/EventUpdateRecord.swift`, `Sources/CheICalMCP/EventKit/EventKitManager.swift`, `Sources/CheICalMCP/EventKit/EventKitManager+KeepLaterEdits.swift`, `Sources/CheICalMCP/EventKit/UndoKeepLaterEdits.swift`, `Sources/CheICalMCP/Server.swift`, `mcpb/manifest.json`, `README.md`, `README_zh-TW.md`, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`, `Tests/CheICalMCPTests/EventUpdateRecordTests.swift`, `Tests/CheICalMCPTests/EventMoveUndoTests.swift`, `Tests/CheICalMCPTests/UndoKeepLaterEditsTests.swift`, `Tests/CheICalMCPTests/UndoKeepLaterEditsWiringTests.swift`, `Tests/CheICalMCPTests/ManifestParityTests.swift`
  - New: `Tests/CheICalMCPTests/EventUpdateFollowWiringTests.swift`
