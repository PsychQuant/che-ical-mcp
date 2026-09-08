## Why

#206 與 #214 共用 undo 堆疊，找不到的提醒事項或事件都可能卡住最上方紀錄。EventKit 的空讀取不能證明永久刪除，原先自動 discard 方案已驗證失敗。

## What Changes

- undo_history 每筆增加穩定 id。
- undo 接受選擇性的 discard_id，明確移除指定且仍在最上方的紀錄。
- stale id、空堆疊與執行中的 undo/redo 會拒絕移除。
- 一般 undo 失敗與週期 occurrence guard 保持既有語意。

## Capabilities

### New Capabilities

- `undo-history-discard`: 以紀錄身分核對的明確歷史移除。

### Modified Capabilities

無。

## Impact

UndoManager.swift、Server.swift、stack/handler tests、manifest 與 undo 文件。操作僅修改記憶體歷史，不呼叫 EventKit。
