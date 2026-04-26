## Why

`EventKitManager.deleteRemindersBatch` 在 catch block 把 `error.localizedDescription` 直接塞進 `failures[].error` 回給 MCP client（`Sources/CheICalMCP/EventKit/EventKitManager.swift:1377`，由 `cleanup_completed_reminders` handler 消費）。

#21 Round 2 安全審查確認：目前 EventKit 的 `NSError` 文字不會內插 reminder title / notes（只是 `"The operation couldn't be completed. (EKErrorDomain error N.)"` 這類類別描述），所以**今天沒洩漏**。但 #32 是 defense-in-depth：把「Apple 將來不會改 error 格式」這個隱式假設拔掉，改成顯式契約，讓 failures[].error 的字面值只能是我們自己產的穩定字串。

時機選在 #31 剛落地之後 — 新的 `EventKitManaging` + `FakeEventKitManager` harness 正好讓我們能腳本化各種 `NSError` 丟進去、斷言 sanitize 後的輸出，這是 #21 / #28 當時沒有的能力。#32 是這個 harness 的首個正式消費者，同時驗證 harness 設計是否真的支撐得起實務測試需求。

## What Changes

- 新增 `EventKitErrorSanitizer` utility（純函式，無狀態）：輸入 `Error`，輸出 `(code: String, rawLog: String)` tuple：
  - `EKErrorDomain` 的 `NSError` → `code = "eventkit_error_<N>"`，其中 `<N>` 是 `NSError.code`
  - 其他 `NSError` → `code = "error_<domain>_<N>"`（domain 取最後一段，移除非字母數字字元）
  - 非 `NSError` 的 Swift `Error` → `code = "error_unknown"`
  - 所有情境下，`rawLog` = 原始 `error.localizedDescription`（只給 stderr 日誌用，不回傳）
- 修改 `EventKitManager.deleteRemindersBatch` catch block（`EventKitManager.swift:1377`）：
  - 呼叫 sanitizer，把 `code` 塞進 `failures[].error`
  - 把 `rawLog` 寫到 `FileHandle.standardError`（operator 仍看得到完整 debug 訊息）
- 修改 `BatchDeleteResult.failures` 型別註解（`EventKitManager.swift:1780`）：docstring 明確寫「`error` 只能是 sanitized code，不可回傳任意 NSError 字串」— 讓未來維護者看到就知道規則
- `cleanup_completed_reminders` handler 的回應 shape 保持不變（`failures[].error` 仍是 string，只是值域收斂）
- 既有的 stable 前置錯誤字串（`"Reminder not found"`、`"Reminder is no longer completed"`）不動 — 那些是我們自己產的，本來就安全

## Non-Goals

- **不處理**其他 8 個 `.localizedDescription` 直接外洩的位置（`Server.swift:1827, 2172, 2184, 2195, 2237, 2388, 2424, 2489`；`EventKitManager.swift:838`）— 本 change 範圍嚴格限縮到 `deleteRemindersBatch` 這一個 `cleanup_completed_reminders` 消費的 catch block，呼應 #31 narrow scope（一 handler、一 harness）。其他 handler 的同類漏洞各自開 follow-up issue 處理。
- **不改變** `failures[].error` 的欄位型別（仍是 `String`）— 不做 breaking change、不加 `{code, message}` object、不加新欄位。未來若 operator debug 需求升高，可在 follow-up 引入分離的 `raw_error` trusted-only 欄位。
- **不列舉**所有 `EKErrorDomain` 的 error code 對應的人類可讀訊息 — 改用 `eventkit_error_<N>` 這種 stable numeric encoding 即可滿足契約（不洩漏 + 穩定），避免自己維護一張容易 drift 的 Apple 錯誤碼對照表。
- **不改** stderr 日誌格式 — raw `localizedDescription` 仍完整寫到 stderr，給 operator 本地除錯用。
- **拒絕** Option 2（UNTRUSTED markers wrapper）：會改變 response shape，且 MCP client 端需要懂如何剝 marker，成本遠大於 Option 1；且 Option 1 已經滿足「不洩漏」這個唯一的安全目標。
- **拒絕** Option 3（純文件化 Apple API 依賴，不改 code）：diagnosis 已確認這是 defense-in-depth，目標就是把隱式依賴移除，純文件化等於不做。

## Capabilities

### New Capabilities

- `eventkit-error-sanitization`: 規範 EventKit 批次操作在 catch block 把 `NSError.localizedDescription` 轉成不會洩漏 user content 的 stable code 的契約，涵蓋純函式 sanitizer 的輸入/輸出、`deleteRemindersBatch` catch-path 對 sanitizer 的呼叫順序、`failures[].error` 的值域限制、以及 operator debug（stderr）路徑。

### Modified Capabilities

（無 — 此 change 引入新 capability，沒有改既有 spec 的既有要求）

## Impact

- **Affected specs**（new）：`openspec/specs/eventkit-error-sanitization/spec.md`
- **Affected code**：
  - `Sources/CheICalMCP/EventKit/EventKitErrorSanitizer.swift`（新檔）
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`（`deleteRemindersBatch` L1377 catch block；`BatchDeleteResult` docstring L1780）
  - `Tests/CheICalMCPTests/EventKitErrorSanitizerTests.swift`（新檔，純函式單元測試）
  - `Tests/CheICalMCPTests/CleanupHandlerTests.swift`（新增 integration test 用 `FakeEventKitManager.scriptDeleteResult` 與 `scriptDeleteError` 驗證 failures[].error 走 sanitizer 路徑）
  - `CHANGELOG.md`（Unreleased security/hardening 條目）
- **Affected issues**：closes #32；需在本 change 內開 follow-up issue 覆蓋剩餘 8 個 `.localizedDescription` 外洩位置（類似 #31 收尾時開 #33-#36 的做法）。
- **No breaking changes**：`failures[].error` 仍是 string、欄位名不變、schema 不變；只是值域從「Apple 可能任意變動的 localized 文字」收斂到「我們產的 stable code」。
