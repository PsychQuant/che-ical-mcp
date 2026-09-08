## Why

事件與提醒事項以相同的 recurrence_rules 名稱回傳欄位與缺值規則不同的陣列，跨工具的用戶端容易選錯解析方式（#198）。直接更動既有型別會破壞已部署的用戶端。

## What Changes

- 新增 event_recurrence_rules 與 reminder_recurrence_rules，分別使用目前各實體的格式。
- 保留 recurrence_rules 作相容別名；文件明確說明型別、日期、缺值及欄位差異。
- 事件遇到未知 frequency 時輸出 unknown 與原始值，避免陣列索引越界。

## Capabilities

### New Capabilities

- `recurrence-read-formats`: 明確命名的事件與提醒事項 recurrence 讀取契約及舊欄位相容性。

### Modified Capabilities

無。既有 recurrence-excluded-dates 定義寫入流程，此次不改其要求。

## Impact

EventFormattingSource.swift、ReminderRecurrence.swift、Server.swift、Validation.swift、recurrence 及 event-formatting 測試、README.md、README_zh-TW.md、docs/REMINDER_RECURRENCE.md、CHANGELOG.md。
