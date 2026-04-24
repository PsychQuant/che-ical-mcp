## 1. Protocol 定義與 EventKitManager conformance

Requirement addressed: `EventKitManaging` protocol exposes only the methods currently tested
Design decision: D1: Protocol scope is minimal — only 3 methods

- [x] 1.1 在 `Sources/CheICalMCP/EventKit/EventKitManager.swift` 新增 `EventKitManaging` protocol，僅宣告三個方法：`listReminders(completed:calendarName:calendarSource:)`、`deleteRemindersBatch(identifiers:onlyCompleted:)`、`requestReminderAccess()`（`Sendable`-constrained 因為 EventKitManager 是 actor，非 class）
- [x] 1.2 讓 `EventKitManager` 宣告 conforms 到 `EventKitManaging`（`actor EventKitManager: EventKitManaging`）；由於方法 signature 相同，不需新增實作
- [x] 1.3 `swift build` 確認 compile 通過且無新 warning
- [x] 1.4 實作 Requirement: Existing `EventKitManager` call sites outside the cleanup handler are NOT refactored in this change —— Server.swift 36 個 eventKitManager call site 一個都沒動

## 2. Handler 對 reminder 屬性的依賴最小化

對應 Decision D4: `MockReminder` is a minimal stand-in, not an `EKReminder` subclass

- [x] 2.1 檢視 `handleCleanupCompletedReminders` 讀取 `EKReminder` 的所有屬性（目前僅 `calendarItemIdentifier`、`isCompleted`），評估是否需要抽 `CleanupReminderDouble` 協定或可用 `EKReminder` 子類 mock
- [~] 2.2 [P] 若需要抽 double：在 `Sources/CheICalMCP/EventKit/EventKitManager.swift` 新增 `CleanupReminderDouble` 協定，讓 `EKReminder` extension conforms；handler 接受 `[any CleanupReminderDouble]`
- [x] 2.3 [P] 若不需要抽 double（`EKReminder` 可在 test 中直接 instantiate）：記錄此決定於 design.md Open Questions 下，skip 此 group 其餘 task
- [x] 2.4 `swift build` 確認改動通過；`swift test` 確認 162 既有 tests 無 regression

## 3. CheICalMCPServer 注入入口

Requirement addressed: `CheICalMCPServer.init` accepts an injected `EventKitManaging` with production default
Design decision: D2: Injection via default-argument init, not DI container

- [x] 3.1 修改 `Sources/CheICalMCP/Server.swift` 的 `CheICalMCPServer` class：將 `private let eventKitManager = EventKitManager.shared` 改為 stored property 並新增 `init(eventKitManager: any EventKitManaging = EventKitManager.shared)` initializer
- [x] 3.2 確認 `main.swift`、`CLIRunner.swift` 等現有實例化位置不需改動（default argument 接住）
- [x] 3.3 `swift build` + `swift test` 確認 production path 無改變
- [x] 3.4 實作 Requirement: Test infrastructure has zero production runtime impact —— 跑 `swift build -c release` 比對前後 binary module list 與 warning 數

## 4. FakeEventKitManager 測試替身

Requirement addressed: `FakeEventKitManager` is scriptable per test
Design decision: D3: `FakeEventKitManager` is per-test scripted, not a stateful fixture

- [x] 4.1 新增 `Tests/CheICalMCPTests/FakeEventKitManager.swift`
- [x] 4.2 [P] 實作 scriptable properties：`listRemindersResult: [EKReminder] = []`、`listRemindersError: Error? = nil`、`deleteRemindersBatchResult: BatchDeleteResult? = nil`、`requestReminderAccessError: Error? = nil`
- [x] 4.3 [P] 實作 invocation recording：`listRemindersCalls: [(completed: Bool?, calendarName: String?, calendarSource: String?)]`、`deleteRemindersBatchCalls: [(identifiers: [String], onlyCompleted: Bool)]`、`requestReminderAccessCallCount: Int`
- [x] 4.4 實作預設行為：若 scripted result/error 未設置，對應 method 以 empty/no-op 返回
- [x] 4.5 實作 helper constructor `fake.reminder(id:completed:title:)` 產生最小可用的測試 reminder（依 task 2 的決定採用 `EKReminder` 或 `CleanupReminderDouble`）

## 5. CleanupHandlerTests 整合測試

Requirement addressed: `CleanupHandlerTests` pins documented contract invariants
Design decision: D5: One test file — `CleanupHandlerTests`

- [x] 5.1 新增 `Tests/CheICalMCPTests/CleanupHandlerTests.swift`，import `MCP` + `@testable import CheICalMCP`
- [x] 5.2 [P] `testF1GuardFiresBeforeListReminders`：arguments 傳 `calendar_source` 無 `calendar_name`，assert throws `ToolError.invalidParameter`，`fake.listRemindersCalls.isEmpty`
- [x] 5.3 [P] `testDryRunFilterModeReturnsPreviewWithoutDeleting`：scripted `listRemindersResult = 3 completed reminders`；dry_run=true；assert `reminders_to_delete.count == 3`、`fake.deleteRemindersBatchCalls.isEmpty`
- [x] 5.4 [P] `testExecuteFilterModeCallsDeleteRemindersBatch`：scripted 相同；dry_run=false；assert `fake.deleteRemindersBatchCalls.count == 1`、`onlyCompleted == false`
- [x] 5.5 [P] `testDryRunBindingModeReturnsSuppliedIds`：reminder_ids=["a","b","c"]、dry_run=true；assert preview 順序一致、`fake.listRemindersCalls.isEmpty`、`fake.deleteRemindersBatchCalls.isEmpty`
- [x] 5.6 [P] `testExecuteBindingModeUsesOnlyCompletedTrue`：reminder_ids=["a"]、dry_run=false；assert `fake.deleteRemindersBatchCalls.last?.onlyCompleted == true`
- [x] 5.7 [P] `testBindingModeRejectsUncompletedReminder`（#28 F1 pin）：FakeEventKitManager 回傳 `BatchDeleteResult(successCount: 0, failedCount: 1, failures: [("a", "Reminder is no longer completed")])`；assert response 的 `failures[0].error` 包含 "no longer completed"、`deleted_ids` 不含 a
- [x] 5.8 [P] `testTotalEqualsUniqueIdentifiersCount`（R2-F2 pin）：scripted 5 reminders 含 2 重複；dry_run=true；assert response.total == 3（deduped count）、`total == deleted_count + failures.count + remaining` holds
- [x] 5.9 [P] `testDuplicateReminderIdsAreDeduped`：reminder_ids=["a","a","b"]；assert final `identifiers` passed to fake 是 `["a","b"]`（保持 first-occurrence order）
- [x] 5.10 [P] `testEmptyReminderIdsThrows`：reminder_ids=[] 不該靜默成功；assert throws（binding 模式下空 ID 陣列沒意義）— 若目前實作是允許則記錄 decision 並改成 assert 回傳 `total=0`
- [x] 5.11 [P] `testResponseShapeStableAcrossThreeBranches`（F8 pin）：跑完 dry-run、execute-empty、execute-non-empty 三 branch；assert 每個 response 都包含 key set `{dry_run, mode, total, deleted_count, deleted_ids, failures, remaining}`
- [x] 5.12 [P] `testLimitRespectsBlastRadiusCap`（F4 pin）：scripted 2000 reminders；limit=500；assert `identifiers.count == 500`、`remaining == 1500`、only 500 passed to fake

## 6. Regression 與驗收

- [x] 6.1 `swift test` 全套通過：162 既有 + 新增 testcase 數（預期 +10~12），總數應為 172+
- [x] 6.2 `swift build -c release` 通過，無 linker warning
- [x] 6.3 人工 smoke test：從 CLI 執行 `CheICalMCP --cli cleanup_completed_reminders dry_run=true` 確認 production path 與改動前行為一致（dry_run 預設為 true，安全）

## 7. 文件更新

- [x] 7.1 `CHANGELOG.md` 的 `[Unreleased]` 下新增 `### Added` 條目描述 `EventKitManaging` + `FakeEventKitManager` + `CleanupHandlerTests`，引用 #31
- [x] 7.2 commit message 引用 `Refs #31`，不用 `Closes`（遵守 IDD 規範）
- [x] 7.3 推送後跑 `/issue-driven-dev:idd-verify #31` 進行 6-AI cross-check 驗證
