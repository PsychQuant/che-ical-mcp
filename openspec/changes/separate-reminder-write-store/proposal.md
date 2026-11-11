## Why

既有提醒事項或提醒事項清單的寫入在 commit 時失敗後，改動會留在 server 唯一的長駐 `EKEventStore` 裡，下一次任何存檔都會把它寫進去，雖然失敗的那次呼叫已經回報錯誤（PsychQuant/che-ical-mcp#459，#274）。`EKEventStore.reset()` 會丟掉它，但 reset 會波及其他同時進行的呼叫。#459 的實測（2026-11-09，iCloud）顯示：commit 失敗的寫入如果是在另一個 store 上做的，那個 store 丟掉之後，失敗的改動不會再落地；同一次實測中只用一個 store 的對照組則會落地。

## What Changes

- 既有提醒事項與提醒事項清單的寫入（修改、完成、刪除、清單改名或換色、清單刪除），以及提醒事項的 undo 與 redo，改在另一個寫入用的 store 上 commit：用識別碼在寫入 store 上重新取出物件，把呼叫端要寫的欄位（封閉列舉）複製過去，在那裡 commit。失敗時那個 store 連同失敗的改動一起丟掉，長駐 store 不受影響。成功時長駐 store 的物件 `rollback()` 再 `refresh()`，讀到剛寫入的值（實測立即可見）。
- 寫入 store 來自一個上限為 4 的池；池滿時呼叫被拒絕，不會開第 11 個 store（實測：一個 process 同時最多 10 個，第 11 個看不到任何資料也不報錯）。
- 一次批次呼叫（`delete_reminders_batch`、`cleanup_completed_reminders`、undo 或 redo 一筆批次紀錄）共用一個寫入 store；其中任一筆寫入失敗後，換一個新的 store 給其餘的列，失敗的改動不會被下一列帶進去。
- 寫入 store 用識別碼找不到物件時，回報為 store 錯誤，不回報成「找不到」。
- 建立（包括它的 #237 補存）與所有事件的寫入仍然在長駐 store 上，`uncheckedKept`（#289）的約定不變。
- 「失敗的改動之後仍可能落地」的錯誤與 `failed_rows_note` 不再適用於這些寫入，改成一般的失敗回報；工具描述、manifest、README 與 CHANGELOG 跟著改。
- 不發 release；binary 有改動，CHANGELOG 的 Unreleased 記一筆。

## Non-Goals

- 不用 `EKEventStore.reset()`，也不把寫入改成序列化或加世代閘門（#459 Diagnosis 的選項 0、1、2）。
- 不改建立與事件的寫入路徑。
- 不重用寫入 store：每次呼叫（或每次批次呼叫）用新的 store，避免沿用另一次呼叫的快取或失敗狀態。

## Capabilities

### New Capabilities

- `reminder-write-store`：既有提醒事項與清單的寫入在另一個 store 上 commit，失敗不留在長駐 store 裡。

### Modified Capabilities

（無）

## Impact

- 影響的檔案：`Sources/CheICalMCP/EventKit/ExistingReminderSave.swift`、新檔 `WriteStorePool.swift` 與 `ReminderFieldCopy.swift`、`EventKitManager.swift`（批次刪除、undo 與 redo 的入口、錯誤類型）、`ReminderDateSync.swift`（log 文字）、`Server.swift` 與 `mcpb/manifest.json` 的工具描述、`README.md`、`README_zh-TW.md`、`CHANGELOG.md`，以及測試。
