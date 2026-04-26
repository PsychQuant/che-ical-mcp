## Context

#32 落地了 `EventKitErrorSanitizer.sanitize(_:)` (`Sources/CheICalMCP/EventKit/EventKitErrorSanitizer.swift:21`) — 單一函式，輸入 `Error`、輸出 `(code, rawLog)`。它對 `EKErrorDomain` 回 `eventkit_error_<N>`、對 bridged Swift Error 回 `error_unknown`、對其他 NSError 回 `error_<slug>_<N>`。`code` 由 `nsError.domain` + `nsError.code.magnitude` 推導，從不讀 `userInfo` 或 `localizedDescription`。`rawLog` 則持有原 `localizedDescription` 給 stderr 使用。

#32 的設計刻意 narrow scope：只用在 `EventKitManager.deleteRemindersBatch:1377` 的 catch path 內，對應 `cleanup_completed_reminders` MCP tool。spec R4 的 regex 值域 (`^(eventkit_error_[0-9]+|error_[a-z0-9_]+_[0-9]+|error_unknown|...)$`) 是這個窄 scope 的 invariant。

#32 closing summary 已記錄 narrow scope 是刻意的，剩餘 10 sites（在 `EventKitManager.swift` + `Server.swift`）追蹤在 #37。重點：這 10 個 sites 的 `localizedDescription` 並非全來自 Apple — 我們自己作者的 `ToolError` / `EventKitError` / `CLIError` 也經這條路徑外洩給 client。Sanitize 它們 = 砍掉作者刻意產的 operator-friendly 英文訊息，UX 退化但無安全收益。

3 個 author-controlled error type 確認：
- `Server.swift:3026` `enum ToolError: LocalizedError`：`.invalidParameter("...")` 與 `.unknownTool(...)`，訊息形如 `"Invalid parameter: title is required"`
- `EventKitManager.swift:1701` `enum EventKitError: LocalizedError`：`.calendarNotFound`、`.accessDenied(...)` 等，訊息含 user-supplied calendar name 但已通過 input validation
- `CLIRunner.swift:7` `enum CLIError: LocalizedError`

關鍵觀察：Foundation 的 `URLError` / `CocoaError` / `POSIXError` 雖然也 conform `LocalizedError`，但訊息是 framework 產的、locale-dependent — 它們不該被當成 trusted。所以 `is LocalizedError` 不能當 trust 判斷。

#37 的 hard problem：在不破 #32 R4 invariant、不退化作者英文訊息的前提下，把 sanitizer pattern 推到全部 10 sites。

## Goals / Non-Goals

**Goals:**

- 10 個 leak sites 的 `error.localizedDescription` 都不再「無條件」流到 MCP client。每個 site 由 type system 決定要 sanitize 還是直接轉發。
- 作者控制的 error types（`ToolError` / `EventKitError` / `CLIError`）的 `errorDescription` 行為**完全不變**：使用者在 client 端看到的訊息仍是 `"Invalid parameter: title is required"`。
- Apple-thrown NSError 在 5 HIGH sites 走 sanitize（new behavior：值域從 Apple 任意文字 → stable code）。
- Outer `Server.swift:989` 的 wire shape（`"Error: \(text)"`）保持不變；`text` 由 dispatch 決定。
- 10 site 的 stderr log 行為一致（`"<handler>(<id>) failed: <rawLog>\n"`），由 helper 集中產生而非 10 份複製。
- #32 R1–R4 spec invariant **完全不動**：`deleteRemindersBatch:1377` 仍呼叫 `sanitize(_:)`，#32 的所有 caller 不受影響。
- 新 marker protocol 是 internal-only，不洩漏到 MCP wire。

**Non-Goals:**

- 不為 5 個沒 fake-seam 的 handler 加新 protocol — 違反 #32/#36 narrow scope；apply phase 改開 follow-up issues。
- 不重構 batch handler 的 response shape（仍 `[(index/event_id/reminder_id), success?, error?]`）。
- 不改 `Server.swift:989` 的 wire format（`"Error: \(text)"`）。client-side parsing impact = 0。
- 不引入 runtime config flag 切換 dispatch policy；marker protocol 是唯一的 trust 訊號。
- 不退化 #32 既有測試契約 — `EventKitErrorSanitizerTests` 全部 PASS、`CleanupHandlerTests` 不變。

## Decisions

### D1. Empty marker protocol，不是擴充 LocalizedError

**Decision**: 新 `protocol TrustedErrorMessage {}` — 空 protocol、無方法要求。`ToolError` / `EventKitError` / `CLIError` 各加一行 `extension ToolError: TrustedErrorMessage {}` opt-in conformance。

**Rationale**:
- `is LocalizedError` 太寬：`URLError` / `CocoaError` / `POSIXError` 也 conform；它們的訊息是 Apple framework 產的、可能含 user-supplied URL / 路徑，等同我們想避免的洩漏 channel。
- 空 protocol 強制 author **顯式** opt-in。新 author error type 的維護者必須主動寫 `: TrustedErrorMessage` 並承擔「這個訊息我保證不洩 user content」的責任。漏寫 = 訊息退化成 sanitized code（safe default）。
- 沒有方法要求 = conformance 成本最低，未來 author error 加一行就好。

**Rejected**:
- `is LocalizedError`：太寬，會誤把 framework Swift errors 當 trusted。
- 顯式 type union（`if error is ToolError || error is EventKitError`）：每加新 author error 要改 sanitizer 內部的 dispatch，違反 Open-Closed。
- 必填方法 protocol（如 `var trustsErrorDescription: Bool { true }`）：runtime override 反而給 maintainer 一條退路，違反「marker = author 簽合約」精神。

### D2. 兩函式 API：`sanitize(_:)` 不變、新 `sanitizeForResponse(_:)`

**Decision**:
```swift
extension EventKitErrorSanitizer {
    static func sanitizeForResponse(_ error: Error) -> SanitizedError {
        if error is TrustedErrorMessage {
            let text = error.localizedDescription
            return SanitizedError(code: text, rawLog: text)
        }
        return sanitize(error)
    }
}
```

**Rationale**:
- 既有 `sanitize(_:)` 的 callers (#32 `deleteRemindersBatch:1377`) 完全不變，spec R1–R4 invariant 保持。
- 新 caller 用 `sanitizeForResponse(_:)`。callers 在 site 層級就決定要不要走 trust path（透過 type system 自動）。
- API 名稱明示意圖：`sanitize` 是無條件 sanitize（給 cleanup_completed_reminders），`sanitizeForResponse` 是 type-aware（給其他 batch handler 與 outer catch）。

**Rejected**:
- 改 `sanitize(_:)` 的行為直接加 trust path：會讓 #32 spec R4 regex 不再是 invariant（trusted message 不滿足 `[0-9]+`），#32 的測試也得改。違反 narrow-scope-don't-break-narrow-scope 原則。
- 加 flag 參數 `sanitize(_:trustAuthored: Bool)`：runtime API 本意應由 type system 表達，flag 多一條維護路徑。

### D3. Helper `writeFailureLog(handler:identifier:error:) -> String`

**Decision**:
```swift
extension EventKitErrorSanitizer {
    @discardableResult
    static func writeFailureLog(
        handler: String,
        identifier: String,
        error: Error
    ) -> String {
        let sanitized = sanitizeForResponse(error)
        FileHandle.standardError.write(
            Data("\(handler)(\(identifier)) failed: \(sanitized.rawLog)\n".utf8)
        )
        return sanitized.code
    }
}
```

10 個 catch sites 改成：
```swift
} catch {
    let code = EventKitErrorSanitizer.writeFailureLog(
        handler: "createEventsBatch",
        identifier: "\(index)",
        error: error
    )
    results.append(["index": index, "success": false, "error": code])
}
```

**Rationale**:
- 10 sites 全部需要「sanitize + 寫 stderr + 拿 code」三件事。helper 之前 #32 narrow scope 一個 site，inline 是合理的；10 sites 沒 helper = 災難維護。
- helper 的存在等同把 #32 的 invariant 「raw log 必寫 stderr，code 才能進 response」落到 type system + 編譯期可驗證的 single source of truth。
- `@discardableResult` 因為 outer catch (`Server.swift:989`) 的 `code` 會被插值進 `"Error: \(code)"`；其他 sites 都會 append 進 array。
- `handler` / `identifier` 參數是 stderr log 的 contextual breadcrumb；對 operator debug 用。

**Rejected**:
- inline 10 次：違反 DRY、未來 maintainer 改一個忘改其他 9 個 → drift。
- helper 只回 code 不寫 stderr：caller 還是要自己寫，維持 10 份複製，省一行不解決問題。
- helper 不接 `handler` / `identifier`：stderr log 失去 context，operator debug 變難。

### D4. Outer catch 的 wire shape 不變

**Decision**: `Server.swift:989` 仍回 `CallTool.Result(content: [.text("Error: \(code)")], isError: true)`，只是 `code` 改由 `EventKitErrorSanitizer.sanitizeForResponse(error).code` 提供。

**Rationale**:
- Wire shape change = 給所有 MCP client 一次 breaking change，要 client 端配合 parser 升級。當下沒有任何 client 解析 `"Error: ..."` 的內部結構（只當人類可讀字串顯示），改 JSON 只是給未來打開的洞，現在沒收益。
- Trust path 下，作者 ToolError 的訊息（`"Invalid parameter: ..."`）原樣放進 `"Error: Invalid parameter: ..."`，client UX 完全不變。
- Apple 路徑下，從 `"Error: The operation couldn't be completed. (EKErrorDomain error 3.)"` 變成 `"Error: eventkit_error_3"`。client 端文字稍變但仍可讀；operator debug 由 stderr 補。

**Rejected**:
- JSON shape `{error_code, error_class, raw}`：breaking change，當下無 consumer 需求。可在未來 #N 開新 issue 評估。
- 直接讓 outer catch 走 `sanitize(_:)` 不分 trust：作者 ToolError 會變成 `"Error: error_cheicalmcp_toolerror_1"`，這正是 client UX 退化的場景，刻意避免。

### D5. spec 用 MODIFIED + ADDED delta，不開新 capability

**Decision**: 對既有 `eventkit-error-sanitization` capability 做 delta：
- 1 條 MODIFIED：R4（`failures[].error` 值域）加註腳澄清「該 invariant 屬於 `sanitize(_:)` caller，與 R6/R7 caller 的值域分離」
- 4 條 ADDED：R5 marker protocol contract、R6 `sanitizeForResponse` dispatch、R7 `writeFailureLog` 契約、R8 outer-catch dispatch

**Rationale**:
- #37 是 #32 capability 的演進、不是新題目。同一個 capability 涵蓋「Apple 錯誤如何 sanitize」+「作者錯誤如何 trust」+「dispatch 接口」是凝聚的。
- 若拆新 capability `error-response-dispatch` 會複雜化 spec 結構（兩個 capability 互依）、archive 順序變脆弱。
- MODIFIED R4 是文字註腳改動，不修 regex 本身 — 對 #32 caller 的行為 0 影響，純補強 spec 可讀性。

**Rejected**:
- 開新 capability `error-response-dispatch`：spec 拓樸複雜化，archive ordering 風險。
- 不改 R4 文字、靠 R6/R7 推論：spec reader 必須跨 4 條 requirement 拼湊「為什麼 cleanup_completed_reminders 不適用 R6」，文件 navigability 退步。

### D6. Test scope：unit 補強，integration 補有 seam 的 sites

**Decision**:
- `EventKitErrorSanitizerTests`：新增 `testSanitizeForResponseTrustedErrorPassesThrough`、`testSanitizeForResponseFrameworkErrorSanitizes`、`testWriteFailureLogReturnsCode`、`testTrustedErrorMessageOptInRequired`（後者 negative test：純 LocalizedError 沒 conform marker → 走 sanitize path）
- 既有 `CleanupHandlerTests` 全部 PASS（#32 narrow scope 完全不動）
- 新 sites 的 integration test：5 個 handler 沒 `FakeEventKitManager`-equivalent seam（`handleCreateEventsBatch` / `handleCreateRemindersBatch` / `handleDeleteEventsBatch` / `handleMoveEventsBatch` / similar-events lookup）— **不在 #37 加 seam**，apply phase 各開一個 destructive-primitive follow-up issue（同 #33 pattern）。
- outer catch (`Server.swift:989`) 的 dispatch：可用既有 dispatch 路徑寫 unit test — 注 `try await server.executeToolCall(name: "unknown_tool")` 會丟 `ToolError.unknownTool` 走 trust path；`try await ... arguments: invalid` 走 ToolError invalidParameter — 這兩個 path 都不需要 fake EventKit。outer-catch 的 framework path 才需 fake，列入 follow-up。

**Rationale**:
- unit 測試覆蓋 `sanitizeForResponse` 的 dispatch 行為（type system 是 invariant carrier，但測試仍要 pin runtime 行為）。
- 不擴 protocol 等於不在 #37 加 5 個新 seam — scope 不爆炸，#34 / #36 trade-off 由那些 follow-up 處理。
- outer catch 的 trust path 用 ToolError 路徑測，無需新 seam — 是 #37 內可達 GREEN 的最大子集。

**Rejected**:
- 在 #37 內擴 `EventKitManaging` protocol 加 4 個新方法：違反 D1 narrow（#36 已預警 `[String]` projection trade-off），且 5 個 handler 各有不同 call shape，protocol 設計需要自己一輪 discuss。
- 跳過所有新 sites integration test：spec 雖型別保證行為，但 wiring drift 仍可能（#32 verify 已示範 — 一個 typo 把 sanitize 換回 raw 也可能不被 catch）。

## Risks / Trade-offs

- **Risk**: 新 author error type 的維護者忘記寫 `: TrustedErrorMessage`。**Mitigation**: spec R5 明文 author 須 opt-in；marker protocol 文件 warning；漏寫的後果是訊息變 sanitized code（safe default，不是洩漏）。
- **Risk**: 某個 author error 的 `errorDescription` 含 user-supplied 字串（如 `"Calendar '\(name)' not found"`）。**Mitigation**: input validators 已 reject 惡意 calendar name；`localizedDescription` 雖含 user content 但 user 是直接呼叫者，不是攻擊者注入路徑（cleanup_completed_reminders 的 threat model 是 `.ics` 共享列表攻擊者，不是直接 caller）。可接受。
- **Trade-off**: helper `writeFailureLog` 的 `handler:identifier:` 是字串而非 enum — 維護者可能拼錯 handler 名稱，stderr log 偏離。**Accepted**: 字串夠靈活；enum 太僵硬反而 maintainer 願意繞開 helper inline 自己寫。stderr log 不破 spec contract，名稱 typo 影響可控。
- **Trade-off**: `sanitizeForResponse` 名稱比 `sanitize` 長。**Accepted**: 命名比簡短重要 — 現場 reader 看得出兩個函式的意圖差異。
- **Risk**: 5 個 handler 的 catch path 仍只靠 unit test + spec 守。一個 maintainer 把 `writeFailureLog(...)` 改回 `error.localizedDescription` 仍可能不被 integration test 抓。**Mitigation**: 已知 gap，跟 #32 同樣 follow-up 處理。
- **Risk**: outer catch (`Server.swift:989`) 走 trust path 時，若呼叫 path 有 wrap：例如某段 code `do { try await ekm.foo() } catch let nsErr as NSError { throw ToolError.invalidParameter(nsErr.localizedDescription) }` — 我們重新 wrap NSError 訊息成 ToolError，outer catch 看到 ToolError → trust → 回原 NSError 文字給 client。**Mitigation**: spec R5 明文 author 不可在 errorDescription 內插值 framework `localizedDescription`；codebase 全 grep `ToolError.invalidParameter` 沒有此 anti-pattern。Apply phase 須再 grep 確認。
