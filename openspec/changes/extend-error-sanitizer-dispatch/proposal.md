## Why

#32 落地 `EventKitErrorSanitizer.sanitize(_:)` 並收緊了 `cleanup_completed_reminders` 的 `failures[].error`。但 #32 verify Devil's Advocate 找出**還有 10 個** `error.localizedDescription` 直接外洩到 MCP client 的 catch sites（`Server.swift` 9 處 + `EventKitManager.swift:838` + outer `Server.swift:989`）。#37 是把 #32 的 narrow scope 推到完整覆蓋，同時解決一個 #32 沒處理的更難問題：**並非所有 `localizedDescription` 都來自 Apple**。

10 個 sites 拆分：
- **5 HIGH（Apple-thrown NSError）**：`EventKitManager.swift:838` (`deleteEventsBatch`)、`Server.swift:2237` (`createEventWithDetails`)、`Server.swift:2388` (`copyEvent`)、`Server.swift:2424` (`deleteEventSeries`)、`Server.swift:2489` (event lookup) — 與 #32 同類威脅，需 sanitize。
- **4 LOW（我們作者的 `ToolError` from `parseFlexibleDate` / `parseTimezone`）**：`Server.swift:1827, 2172, 2184, 2195` — 訊息是我們自己寫的英文（`"Invalid parameter: ..."`），完全不來自 Apple。Sanitize 等於把作者意圖的 operator-friendly 訊息變成 `"error_cheicalmcp_..._1"` opaque code。
- **1 MIXED（outer `handleToolCall` catch）**：`Server.swift:989` 任何 handler throw 都落在這裡，可能是 ToolError 或 Apple NSError。需要型別感知的 dispatch。

#32 的單一 `sanitize(_:)` API 解不了這個非對稱性 — 它只認 NSError 結構，不分作者來源。#37 引入**型別驅動 dispatch** 把這個區分變成 Swift type system 的責任，讓未來 maintainer 不需要每個 catch site 自己 classify。

時機選在 #32 closing summary 裡 follow-up issue 已寫進 #37（含 outer-catch 增量），且 `EventKitErrorSanitizer` 剛被 archive 進 `openspec/specs/eventkit-error-sanitization/spec.md`。本 change 對該 capability 做 additive 擴充。

## What Changes

- 新增 `protocol TrustedErrorMessage` — 空 marker protocol，任何作者可 opt-in 宣告「這個 error type 的 `errorDescription` 是我們手寫的英文，可以直接轉發給 client，不需要 sanitize」。
- 把 `ToolError`（`Server.swift:3026`）、`EventKitError`（`EventKitManager.swift:1701`）、`CLIError`（`CLIRunner.swift:7`）三個既有的 `LocalizedError` enum 全部加 `: TrustedErrorMessage` 空 conformance。
- 新增 `EventKitErrorSanitizer.sanitizeForResponse(_:) -> SanitizedError`：
  - 若 `error is TrustedErrorMessage` → 回 `SanitizedError(code: error.localizedDescription, rawLog: error.localizedDescription)`（trusted path）
  - 否則 → 委派給既有 `sanitize(_:)`（保持 #32 的 `eventkit_error_<N>` / `error_<slug>_<N>` / `error_unknown` 三條 path）
- 新增 helper `EventKitErrorSanitizer.writeFailureLog(handler:identifier:error:) -> String`：對 caller 一次完成「呼叫 sanitizeForResponse + 寫 raw 到 stderr + 回傳 code」三件事，消除 10 sites 各自複製貼上 stderr 寫入。Returns 是 `code` 字串，caller 直接 append 進 `failures[]`。
- 把 10 個 catch sites 全部從 `error.localizedDescription` 改成 `EventKitErrorSanitizer.writeFailureLog(handler: "<name>", identifier: <id>, error: error)`：
  - HIGH 5 sites：實際行為改變（從 Apple 文字 → sanitized code）
  - LOW 4 sites：行為不變（trusted path 回傳原 `localizedDescription`），只是統一過 dispatch
  - MIXED 1 site (`Server.swift:989`)：保留 `"Error: \(code)"` 文字 shape 不破壞 wire format；`code` 由 dispatch 決定
- `cleanup_completed_reminders` / `delete_reminders_batch` 的 `EventKitManager.deleteRemindersBatch` (`EventKitManager.swift:1377`) **不變** — 仍用 #32 的 `sanitize(_:)`，保持窄值域 spec R4 invariant。新 API 不影響 #32 的契約。
- 擴充既有 spec capability `eventkit-error-sanitization`：
  - **MODIFIED** R4（cleanup_completed_reminders 值域）— 維持原 regex 不動，補一條註腳「此 R4 invariant 僅針對 `sanitize(_:)` 的 caller；`sanitizeForResponse(_:)` 的 caller 走 R5」
  - **ADDED** R5: `TrustedErrorMessage` marker protocol 契約（空 protocol、opt-in conformance、author 必須保證 `errorDescription` 不洩漏 user content）
  - **ADDED** R6: `sanitizeForResponse(_:)` 的 dispatch 規則（trusted → 原值；其他 → `sanitize`）
  - **ADDED** R7: `writeFailureLog(handler:identifier:error:)` 的契約（呼叫 `sanitizeForResponse`、寫 stderr、回 code）
  - **ADDED** R8: `Server.swift:989` outer-catch 必須走 `sanitizeForResponse`，輸出維持 `"Error: \(code)"` 文字 shape
- CHANGELOG `### Security` Unreleased 條目記錄 #37 完整 scope。

## Non-Goals

- **不重構** `Server.swift` 既有 batch handler 的 response shape。每個 site 仍是 `["index": …, "success": false, "error": …]` 或 `["event_id": …, "error": …]`；只改 `error` 欄位的值來源。
- **不引入** dispatch 政策切換的 config flag。Marker protocol 是唯一的「trust」訊號，沒有 runtime override。
- **不擴充** `EventKitManaging` protocol。5 個沒有 fake-injectable seam 的 handler（`handleCreateEventsBatch`、`handleCreateRemindersBatch`、`handleDeleteEventsBatch`、`handleMoveEventsBatch`、similar-events lookup）的 integration test 開 follow-up issues 在 apply phase 處理，不在 #37 scope。
- **不變更** `Server.swift:989` 的 wire shape（`"Error: \(text)"`）。`{error_code, error_class}` JSON 重構是 client breaking change，留待未來真有 client 需求時做。
- **不沿用 #32 的 `sanitize(_:)` 處理新 sites**。它的窄值域對 ToolError 會丟失 operator-friendly 訊息；#37 必須引入 trusted-aware dispatch。
- **拒絕 Option A（uniform sanitize all 10 sites）**：4 LOW sites 的作者英文訊息會變成 `error_cheicalmcp_..._1`，operator UX 退化嚴重，且毫無安全收益。
- **拒絕 Option B（selective by-class，無 type system）**：依賴每個 maintainer 為新 catch site 正確 classify Apple-vs-author，未來 drift 風險高。
- **拒絕「`is LocalizedError` 當 trust 訊號」**：`URLError` / `CocoaError` / `POSIXError` 等 Foundation Swift errors 也 conform 但內容是 framework-produced，會誤判。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `eventkit-error-sanitization`: 由「單一 `sanitize(_:)` 把 Apple `localizedDescription` 收斂成 stable code」擴展為「型別驅動 dispatch — 作者錯誤經 marker protocol 直接轉發、framework 錯誤經 sanitize」。新增 marker protocol、新 dispatch API、helper、4 條 ADDED requirements 涵蓋 `sanitizeForResponse`/`writeFailureLog`/outer-catch/trust contract；既有 R1–R4 不動（#32 narrow path 完全保留）。

## Impact

- **Affected specs**: `openspec/specs/eventkit-error-sanitization/spec.md`（delta：1 modified note + 4 added requirements）
- **Affected code**:
  - `Sources/CheICalMCP/EventKit/EventKitErrorSanitizer.swift`：新增 `protocol TrustedErrorMessage`、`sanitizeForResponse(_:)`、`writeFailureLog(handler:identifier:error:)`
  - `Sources/CheICalMCP/Server.swift`：3 個 LocalizedError enum 加 `: TrustedErrorMessage` conformance；10 個 catch blocks 改用 `writeFailureLog`
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`：1 個 LocalizedError enum (`EventKitError`) 加 conformance；`deleteEventsBatch:838` catch 改用 `writeFailureLog`
  - `Sources/CheICalMCP/CLIRunner.swift`：`CLIError` 加 conformance
  - `Tests/CheICalMCPTests/EventKitErrorSanitizerTests.swift`：擴充 — 新增 `sanitizeForResponse` 單元測試（trusted path + framework path 各 N case）
  - `CHANGELOG.md`：Unreleased Security 條目
- **Affected issues**：closes #37；apply phase 預計開 5 個 follow-up issues（每個沒有 injectable seam 的 handler 一個 destructive-primitive integration test gap）。
- **No wire breaks**：所有 4 個既有 site shapes 保持（`failures[]` array、`results[]` array、outer `"Error: \(text)"`）；只是 `error` 欄位值域擴充。
- **No new wire dependency**：`TrustedErrorMessage` 是 internal-only protocol，不洩漏到 MCP wire。
