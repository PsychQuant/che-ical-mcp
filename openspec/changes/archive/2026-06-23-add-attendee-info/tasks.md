## 1. 核心實作

- [x] 1.1 在 `ParticipantFormatting.swift` 新增 `formatParticipant(_ participant: EKParticipant) -> [String: Any]` 方法，實作 email extraction from EKParticipant URL（去除 `mailto:` 前綴，non-mailto 保留原始 URL）和 enum values mapped to human-readable strings（role/status/type 映射）
- [x] 1.2 在 `ParticipantFormatting.swift` 新增 `formatAttendeesInfo(_ event: EKEvent) -> (attendees, organizer)` 方法，回傳 attendees 陣列和 organizer 物件，event 無參與者時各回傳 nil
- [x] 1.3 修改 `Server.swift` 中 event dict 建構：抽取為共用 `formatEventDict`，自動包含 attendees/organizer

## 2. 所有 Event Handler 一致性

- [x] [P] 2.1 `search_events` handler 已改用 `formatEventDict`，自動包含 attendees/organizer
- [x] [P] 2.2 `list_events_quick` handler 已改用 `formatEventDict`，同上
- [x] [P] 2.3 `check_conflicts` handler 已改用 `formatEventDict`，同上
- [x] [P] 2.4 `create_event` handler — 回傳純文字訊息（EventKit 無法設定 attendees，新建事件不會有 attendees）
- [x] [P] 2.5 `update_event` handler — 回傳純文字訊息（同上理由）
- [x] [P] 2.6 `copy_event` handler — 回傳純文字訊息（同上理由）
- [x] [P] 2.7 `find_duplicate_events` handler — 使用 DuplicateEventPair struct（不持有 EKEvent），attendee 不適用

## 3. 抽取共用邏輯

- [x] 3.1 將 event dict 建構邏輯抽取為共用的 `formatEventDict(_ event: EKEvent) -> [String: Any]` 方法，包含 attendees/organizer，確保一致性

## 4. 處理 attendee with nil name 的邊界情況

- [x] 4.1 在 `formatParticipant` 中處理 `EKParticipant.name == nil`：`name` 設為 NSNull（JSON null），`email` 仍從 URL 提取
- [x] 4.2 在 `formatParticipant` 中處理 unknown enum value：`@unknown default` 回傳 `"unknown"`

## 5. 文件更新

- [x] [P] 5.1 更新 `README.md` 的 event response 欄位說明，加入 attendees 和 organizer 欄位文件
- [x] [P] 5.2 更新 `README_zh-TW.md` 同上
- [x] [P] 5.3 更新 `mcpb/manifest.json` 中受影響工具的 description（提及 attendee 欄位）
