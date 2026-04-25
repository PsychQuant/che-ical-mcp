# Tasks

## 0. Requirement coverage map

- [x] 0.1 Requirement 'Error Sanitizer produces stable codes for NSError' — covered by Tasks 1.2, 1.3, 1.4, 1.5, 1.6, 2.3, 2.4, 2.6
- [x] 0.2 Requirement 'Sanitizer returns raw log for operator diagnostics' — covered by Tasks 1.7, 2.2, 2.4
- [x] 0.3 Requirement 'deleteRemindersBatch catch block routes errors through the sanitizer' — covered by Tasks 4.1, 4.2, 4.5
- [x] 0.4 Requirement 'cleanup_completed_reminders response reflects sanitized codes end-to-end' — covered by Tasks 3.1, 3.2, 4.5

## 1. Unit tests — `EventKitErrorSanitizer` (TDD Red)

- [x] [P] 1.1 新增 `Tests/CheICalMCPTests/EventKitErrorSanitizerTests.swift` with `@testable import CheICalMCP`
- [x] [P] 1.2 `testEventKitDomainProducesEventkitErrorN` — `NSError(domain: EKErrorDomain, code: 3)` → `code == "eventkit_error_3"`
- [x] [P] 1.3 `testValueMappingTable` — table-driven: `(EKErrorDomain, 0)`→`eventkit_error_0`、`(NSCocoaErrorDomain, 256)`→`error_nscocoaerrordomain_256`、`(com.apple.foundation, 42)`→`error_foundation_42`、`(NSPOSIXErrorDomain, 1)`→`error_nsposixerrordomain_1`
- [x] [P] 1.4 `testDomainSlugStripsDotPrefixAndNonAlnum` — `(my-custom.sub-domain, 7)` → `error_sub_domain_7`
- [x] [P] 1.5 `testUserInfoIsNeverInterpolated` — NSError with `NSLocalizedDescriptionKey: "Buy groceries at Whole Foods"` + `NSLocalizedFailureReasonErrorKey: "Apartment 4B notes"` → assert `code` 不含 `"Buy"` / `"groceries"` / `"Whole Foods"` / `"Apartment 4B"` / `"notes"` 任何 substring
- [x] [P] 1.6 `testNonNSErrorSwiftErrorCollapses` — 定義 `enum LocalError: Error { case foo }`, `sanitize(.foo).code == "error_unknown"`
- [x] [P] 1.7 `testRawLogEqualsLocalizedDescription` — NSError with `localizedDescription = "X"` → `rawLog == "X"`
- [x] [P] 1.8 跑 `swift test --filter EventKitErrorSanitizerTests`，確認全部 fail with `cannot find 'EventKitErrorSanitizer'`（RED）

## 2. Implementation — `EventKitErrorSanitizer`

- [x] 2.1 新增 `Sources/CheICalMCP/EventKit/EventKitErrorSanitizer.swift`
- [x] 2.2 定義 `struct SanitizedError: Sendable, Equatable { let code: String; let rawLog: String }`
- [x] 2.3 定義 `enum EventKitErrorSanitizer { static func sanitize(_ error: Error) -> SanitizedError }`
- [x] 2.4 `sanitize` 實作：
  - NSError bridging（`error as NSError` always succeeds in Swift）→ 取 `.domain` / `.code` / `.localizedDescription`
  - If `nsError.domain == EKErrorDomain`（常數從 `import EventKit` 拿）→ code = `"eventkit_error_\(nsError.code)"`
  - Else：`slug = slugifyDomain(nsError.domain)`, code = `"error_\(slug)_\(nsError.code)"`
  - `rawLog = nsError.localizedDescription`
  - 回傳 `SanitizedError(code:, rawLog:)`
- [x] 2.5 Note：純 Swift `Error` 經 `as NSError` bridging 後仍有 domain（例如 `"CheICalMCP.SomeError"`）與 `code = 1`；Spec 的 `"error_unknown"` 情境指的是我們刻意放寬的 fallback — 實務上 bridging 會把它映到 `error_<slug>_<N>`。Sanitizer 需偵測 bridging 產生的 stub domain（格式 `"\(ModuleName).\(TypeName)"`）並回 `"error_unknown"` — 判斷條件：domain 不含 `"."` 前的第一段是已知 framework（`NS*` / `com.apple.*` / `EKErrorDomain`）否則視為 Swift-bridged → `"error_unknown"`
- [x] 2.6 實作 `private static func slugifyDomain(_ domain: String) -> String`：
  - 取 `.` 切開最後一段（無 `.` 則全字串）
  - 對每字元：ASCII letter → lowercased；ASCII digit → 保留；其他 → `_`
- [x] 2.7 單元測試驗證 slug：加 `testSlugifyRules` — `"my-custom.sub-domain"` → `"sub_domain"`；`"EKErrorDomain"` → `"ekerrordomain"`（但實際 path 用 `eventkit_error_` prefix 不走 slug）
- [x] 2.8 跑 `swift test --filter EventKitErrorSanitizerTests`，確認全部 GREEN

## 3. Integration test — catch-block routing（TDD Red，平行於 Task 1）

- [x] [P] 3.1 在 `Tests/CheICalMCPTests/CleanupHandlerTests.swift` 加 `testBindingModeSanitizesEventKitErrorInFailures`：
  - 腳本 `fake.scriptDeleteResult(BatchDeleteResult(successCount: 0, failedCount: 1, failures: [("r1", "eventkit_error_3")]))`
  - 呼叫 handler `{"reminder_ids": ["r1"], "dry_run": false}`
  - 斷言 response `failures[0]["error"] == "eventkit_error_3"`
  - 斷言 response `failures[0]["reminder_id"] == "r1"`
- [x] [P] 3.2 加 `testFailuresErrorMatchesAllowedValueDomain` — 遍歷上一測試 response 的 `failures[].error`，assert matches regex `^(eventkit_error_[0-9]+|error_[a-z0-9_]+_[0-9]+|error_unknown|Reminder not found|Reminder is no longer completed)$`
- [x] 3.3 跑 `swift test --filter CleanupHandlerTests`，確認 3.1/3.2 PASS（因為 fake 直接把 sanitized code 塞進去，不需要 sanitizer 實作 — 但驗證 handler → response 路徑沒有額外變形）

## 4. Wire sanitizer into `deleteRemindersBatch`

- [x] 4.1 在 `EventKitManager.swift:1376-1378` 的 catch block 改寫：
  ```swift
  } catch {
      let sanitized = EventKitErrorSanitizer.sanitize(error)
      FileHandle.standardError.write(Data("deleteRemindersBatch(\(id)) failed: \(sanitized.rawLog)\n".utf8))
      failures.append((id, sanitized.code))
  }
  ```
- [x] 4.2 更新 `BatchDeleteResult.failures` 的 docstring（`EventKitManager.swift:1780` 附近）：加註「catch path 的 `error` 值必須由 `EventKitErrorSanitizer` 產生；呼叫者不可直接塞 raw `localizedDescription`」
- [x] 4.3 新增 `testDeleteRemindersBatchCatchBlockUsesSanitizer` 到 `EventKitErrorSanitizerTests.swift`（或新檔 `EventKitManagerSanitizerWiringTests.swift`）— 這是 primitive-level test，補 #33 不在本 change scope 但 #32 範圍內的最小驗證：用真的 EventKitManager 跑不到（需 TCC），所以改寫為 `FakeEventKitManager` 以外的**整合等價**：import EventKit, 建 `NSError(domain: EKErrorDomain, code: 3)`, 呼叫 sanitizer 直接斷言（已被 Task 1 覆蓋） → **取消此 task 改紀錄為已由 Task 1 覆蓋**
- [x] 4.4 跑 `swift build` 確認 compile clean
- [x] 4.5 跑 `swift test` 全套 PASS

## 5. Security / audit review（`.spectra.yaml` audit: true）

- [x] 5.1 走一遍 design D2 white-list：sanitizer 的 `slugifyDomain` 輸入若含 zero-width / control char / non-ASCII → 輸出是否仍為純 `[a-z0-9_]`？補測試 `testSlugHandlesNonASCII` —`"com.日本.\u{200B}x"` → 斷言輸出只含 `[a-z0-9_]`
- [x] 5.2 走一遍 Scoundrel 視角：惡意 user 能否透過建立含特殊字元 title 的 reminder 觸發 EventKit error 讓特殊字元出現在 `NSError.domain`？→ 不可能（domain 由 framework 產，非 user-controlled），紀錄在 design.md「Risks」的補充
- [x] 5.3 走一遍 Lazy Developer 視角：下一個 dev 會不會誤用 sanitizer 去改別的 catch block 卻忘記寫 stderr？→ 5.4 處理
- [x] 5.4 在 `EventKitErrorSanitizer.swift` 檔頭加 10 行內 doc comment：「本 sanitizer 只處理 `failures[].error` 外洩場景；若用在別處，請確認呼叫者有獨立管道保留 rawLog（stderr 或其他 trusted channel）」

## 6. CHANGELOG + Follow-ups

- [x] 6.1 在 `CHANGELOG.md` 的 `## [Unreleased]` 底下新增 `### Security` 區塊（若未存在）並加條目：
  - `- Sanitized EventKit error messages in failures[].error for cleanup_completed_reminders (hardening, #32). Previously passed NSError.localizedDescription verbatim; now returns stable codes like "eventkit_error_3". Raw error still logged to stderr.`
- [x] 6.2 開 follow-up issue 「Sanitize .localizedDescription in other 8 batch-handler catch sites」— body 列出 `Server.swift:1827,2172,2184,2195,2237,2388,2424,2489` 與 `EventKitManager.swift:838` 共 9 個 site、引用 #32 為 pattern reference
- [x] 6.3（可選）開 follow-up issue 「Consider separate raw_error trusted field in failures[]」— 若未來 operator 從 MCP client 端 debug 的需求升高再啟動

## 7. Design decision coverage map

- [x] 7.0.1 Design decision D1 '純函式 sanitizer，不是 method on error' — realized by Tasks 2.1–2.4
- [x] 7.0.2 Design decision D2 'Code 格式：eventkit_error_N / error_domain_N / error_unknown' — realized by Tasks 1.2, 1.3, 2.4, 2.5, 2.6
- [x] 7.0.3 Design decision D3 'Raw log 寫 stderr，不回 response' — realized by Tasks 2.2, 4.1
- [x] 7.0.4 Design decision D4 '範圍限縮到 deleteRemindersBatch 單一 catch block' — realized by Tasks 4.1, 6.2
- [x] 7.0.5 Design decision D5 'BatchDeleteResult.failures tuple 不動' — realized by Task 4.2

## 7. Verification entry

- [x] 7.1 跑 `swift test` 全 PASS（預期 175+ tests）
- [x] 7.2 跑 `swift build -c release` 清晰
- [x] 7.3 commit：`feat: sanitize failures[].error via EventKitErrorSanitizer (#32)`
- [x] 7.4 commit 訊息引用 #32 但**不用** `Closes` / `Fixes` trailer（依 `common-git-workflow` + `idd-implement` 鐵律）
- [x] 7.5 準備進 `/idd-verify #32`
