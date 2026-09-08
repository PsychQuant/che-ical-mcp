## Context

UndoManager 以 UndoRecord 保存事件與提醒事項；Server 的 undo/redo 在 pop 後 await EventKit，不能假設 await 期間不會收到另一請求。

## Goals / Non-Goals

Goals：不重啟即可越過卡住的最上方紀錄，保護新插入的紀錄與執行中的歷史操作。
Non-Goals：不推定永久刪除、不自動跳過、不從中間刪紀錄、不刪除事件或提醒事項、不新增 redo 歷史。

## Decisions

### 穩定紀錄身分

UndoRecord 新增 UUID，pop/restore 保留同一 ID。undo_history 輸出 id 與既有 index/time/description。index 會變動，不能作刪除依據。

### 原子移除與執行鎖

CalendarUndoManager.discardUndo(expectedID:) 在 actor 的同步方法中核對 busy、empty、top.id，再移除。beginUndo/beginRedo 設 active record ID，成功 finish 或失敗 restore/discard 後釋放。新移除不跨 await，因此新紀錄不能插入核對與移除之間。

## Implementation Contract

undo 的 discard_id 省略時維持一般 undo；存在時必須為非空 UUID 字串（null、布林、數字、物件均拒絕）。成功輸出 action=discarded_undo、success=true、id、description、undo_available、redo_available，不執行 EventKit，也不把被移除紀錄送入 redo。失敗回傳既有 MCP error 路徑，包含固定的 busy/empty/stale 說明。無論最上方是事件、提醒事項或 batch 都採相同規則。stale ID 重送不得移除下一筆。

undo_history 的 entries/counts 由單次 actor snapshot 取得。EventKit 查找失敗仍使用既有 restore；原先未通過驗證的 lookup branch 不合併。

## Risks / Trade-offs

ID 是操作選取依據而非授權機制；現有 MCP 連線權限不變。明確 discard 無法復原，因此 undo 保持 destructiveHint:true，文件要求先查看歷史再指定 ID。歷史在程序重啟後消失，舊 ID 因而失效。
