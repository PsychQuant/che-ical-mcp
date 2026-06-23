## Why

GitHub issue #17：使用者回報 event 回傳中缺少 attendees 資訊。PRIVACY.md 已聲明收集 attendees，但程式碼從未實作。EventKit 的 `EKEvent.attendees` 和 `EKEvent.organizer` 是唯讀屬性，完全可用但目前被忽略。對 LLM 消費者而言，attendees 是理解會議脈絡的重要資訊。

## What Changes

- 所有回傳 event 的 JSON 中新增 `attendees` 陣列（name、email、role、status、type、is_current_user）
- 所有回傳 event 的 JSON 中新增 `organizer` 物件（name、email、is_current_user）
- 受影響的 handlers：`list_events`、`search_events`、`list_events_quick`、`check_conflicts`、`create_event`（回傳）、`update_event`（回傳）、`copy_event`（回傳）
- 從 `EKParticipant.url` 提取 email（去除 `mailto:` 前綴）
- 將 enum raw values 映射為可讀字串（如 `accepted`、`required`、`person`）

## Non-Goals

- **不新增 attendee 寫入功能**：EventKit 的 attendees 是唯讀的，無法透過 API 新增/移除參與者
- **不建立新的 MCP tools**：這是現有 event output 的擴充，不需要新工具
- **不修改 reminders**：提醒事項沒有 attendees 概念

## Capabilities

### New Capabilities

- `event-attendees`: 在 event JSON 回傳中暴露 attendees 和 organizer 資訊（唯讀）

### Modified Capabilities

（無）

## Impact

- 受影響的程式碼：`Sources/CheICalMCP/Server.swift`（event dict 建構，約 4-5 處）
- 受影響的文件：`README.md`、`README_zh-TW.md`（attendee 欄位說明）
- 受影響的 tool descriptions：所有回傳 event 的工具描述需提及 attendee 欄位
- 無 breaking changes — 新增的都是 optional 欄位
