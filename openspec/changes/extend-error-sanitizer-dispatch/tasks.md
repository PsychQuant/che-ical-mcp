# Tasks

## 0. Requirement coverage map

- [x] 0.1 Requirement 'TrustedErrorMessage marker protocol opts a Swift error type into pass-through dispatch' — covered by Tasks 2.1, 3.1–3.4, 5.1–5.4
- [x] 0.2 Requirement 'sanitizeForResponse dispatches by trust marker' — covered by Tasks 2.2, 5.5–5.7
- [x] 0.3 Requirement 'writeFailureLog combines stderr write with sanitization' — covered by Tasks 2.3, 5.8–5.9
- [x] 0.4 Requirement 'Outer handleToolCall catch routes through sanitizeForResponse' — covered by Tasks 4.10
- [x] 0.5 Requirement 'Affected non-cleanup catch blocks dispatch via writeFailureLog' — covered by Tasks 4.1–4.9, 6.1–6.2
- [x] 0.6 Requirement 'cleanup_completed_reminders response reflects sanitized codes end-to-end' (MODIFIED) — covered by absence of change to `EventKitManager.swift:1377` catch block; the modification is a documentation note in the spec only, with no task because no code change is required. Verified via Task 4.12 grep guard which whitelists this site.

## 1. Unit tests — `sanitizeForResponse` + `TrustedErrorMessage` (TDD Red)

- [x] [P] 1.1 Extend `Tests/CheICalMCPTests/EventKitErrorSanitizerTests.swift` (no new file). New section header `// MARK: - sanitizeForResponse trusted-vs-framework dispatch`.
- [x] [P] 1.2 `testSanitizeForResponseTrustedErrorPassesThrough` — `let err = ToolError.invalidParameter("foo"); let r = EventKitErrorSanitizer.sanitizeForResponse(err); XCTAssertEqual(r.code, "Invalid parameter: foo"); XCTAssertEqual(r.rawLog, r.code)`.
- [x] [P] 1.3 `testSanitizeForResponseFrameworkErrorMatchesSanitize` — `let err = NSError(domain: EKErrorDomain, code: 3); XCTAssertEqual(EventKitErrorSanitizer.sanitizeForResponse(err), EventKitErrorSanitizer.sanitize(err))`.
- [x] [P] 1.4 `testSanitizeForResponseFoundationLocalizedErrorTakesFrameworkBranch` — `let err = URLError(.notConnectedToInternet); let r = EventKitErrorSanitizer.sanitizeForResponse(err); XCTAssertTrue(r.code.hasPrefix("error_")); XCTAssertNotEqual(r.code, err.localizedDescription)`. Pins R5 negative-case (URLError must NOT be trusted).
- [x] [P] 1.5 `testTrustedErrorMessageMarkerIsEmptyProtocol` — assert via type system: `protocol _NoMembers {}; XCTAssertTrue((TrustedErrorMessage.self as Any) is _NoMembers.Type)` (compile-time guard the protocol stays empty; if maintainer adds a method requirement, this test breaks). NOTE: simpler form may be needed depending on Swift runtime support — fallback is `func acceptsAnyConformer<T: TrustedErrorMessage>(_ x: T) {}` + `acceptsAnyConformer(ToolError.invalidParameter("x"))` to prove no method-requirement obstruction.
- [x] [P] 1.6 `testThreeAuthorErrorTypesConformTrustedErrorMessage` — `XCTAssertTrue(ToolError.invalidParameter("x") is TrustedErrorMessage)`, same for `EventKitError.calendarNotFound(identifier: "x")`, same for `CLIError` (use any case it has).
- [x] [P] 1.7 跑 `swift test --filter EventKitErrorSanitizerTests` → 全部 fail（cannot find `sanitizeForResponse` / cannot find `TrustedErrorMessage`）— RED confirmed.

## 2. Implementation — sanitizer extension

- [x] 2.1 In `Sources/CheICalMCP/EventKit/EventKitErrorSanitizer.swift`, add `public protocol TrustedErrorMessage {}` immediately above the existing `enum EventKitErrorSanitizer` declaration. Doc comment 4 lines: purpose + opt-in author contract + R5 reference + warning that `is LocalizedError` would be too broad.
- [x] 2.2 In the same file's `extension EventKitErrorSanitizer` (existing or new), add `static func sanitizeForResponse(_ error: Error) -> SanitizedError`. Body: `if error is TrustedErrorMessage { let s = error.localizedDescription; return SanitizedError(code: s, rawLog: s) }; return sanitize(error)`. Doc comment 6 lines: dispatch rule + spec R6 link + example of trust contract + reminder this is the API for non-cleanup callers.
- [x] 2.3 In the same file, add `@discardableResult static func writeFailureLog(handler: String, identifier: String, error: Error) -> String`. Body: `let s = sanitizeForResponse(error); FileHandle.standardError.write(Data("\(handler)(\(identifier)) failed: \(s.rawLog)\n".utf8)); return s.code`. Doc comment 5 lines: contract + spec R7 link + signature note (`@discardableResult` reason + why `handler`/`identifier` parameters).
- [x] 2.4 跑 `swift test --filter EventKitErrorSanitizerTests` after Task 3 conformances land — Tests 1.2/1.3/1.4 pass; 1.5/1.6 still pending until Task 3.

## 3. Author error type conformances

- [x] 3.1 In `Sources/CheICalMCP/Server.swift`, immediately after `enum ToolError: LocalizedError { ... }` definition, add `extension ToolError: TrustedErrorMessage {}` empty conformance. No other change to `ToolError`.
- [x] 3.2 In `Sources/CheICalMCP/EventKit/EventKitManager.swift`, after `enum EventKitError: LocalizedError { ... }`, add `extension EventKitError: TrustedErrorMessage {}` empty conformance.
- [x] 3.3 In `Sources/CheICalMCP/CLIRunner.swift`, after `enum CLIError: LocalizedError { ... }`, add `extension CLIError: TrustedErrorMessage {}` empty conformance.
- [x] 3.4 跑 `swift build` — confirm all three conformances compile. Run `swift test --filter EventKitErrorSanitizerTests` — Tests 1.5/1.6 now PASS. All seven 1.x tests GREEN.
- [x] 3.5 Audit pass: grep for any other `enum.*: LocalizedError` in `Sources/`. If found, evaluate per-case whether to add `: TrustedErrorMessage`. Currently expected to find exactly the three above (verified at diagnose time); audit defends against future additions slipping in unreviewed.

## 4. Wire `writeFailureLog` into 10 catch sites

- [x] [P] 4.1 `EventKitManager.swift:838` (`deleteEventsBatch` per-item catch) — replace `failures.append((item.identifier, error.localizedDescription))` with `let code = EventKitErrorSanitizer.writeFailureLog(handler: "deleteEventsBatch", identifier: item.identifier, error: error); failures.append((item.identifier, code))`.
- [x] [P] 4.2 `Server.swift:1827` (per-handler `parseFlexibleDate`/`parseTimezone` catch) — replace `"error": error.localizedDescription` with `"error": EventKitErrorSanitizer.writeFailureLog(handler: "<handler-name>", identifier: "\(index)", error: error)`. Substitute `<handler-name>` with the actual function name (read 30 lines up to identify).
- [x] [P] 4.3 `Server.swift:2172` (`handleCreateEventsBatch` parseTimezone catch) — same pattern, `handler: "createEventsBatch"`, `identifier: "\(index)"`.
- [x] [P] 4.4 `Server.swift:2184` (`handleCreateEventsBatch` parseFlexibleDate start catch) — same pattern, same handler/identifier.
- [x] [P] 4.5 `Server.swift:2195` (`handleCreateEventsBatch` parseFlexibleDate end catch) — same pattern, same handler/identifier.
- [x] [P] 4.6 `Server.swift:2237` (`handleCreateEventsBatch` similar-events / save catch) — same pattern, same handler/identifier. Re-read 10 lines context to confirm whether identifier is `index` or `event.eventIdentifier`.
- [x] [P] 4.7 `Server.swift:2388` (`handleCreateRemindersBatch` per-item catch — actually `handleMoveEventsBatch` per re-reading; correct handler name from context) — same pattern. Use `eventId` parameter as identifier.
- [x] [P] 4.8 `Server.swift:2424` (`handleDeleteEventsBatch` `deleteEventSeries` per-item catch) — same pattern, `handler: "deleteEventsBatch"`, `identifier: id`.
- [x] [P] 4.9 `Server.swift:2489` (`handleDeleteEventsBatch` dry-run preview lookup catch) — same pattern, same handler, `identifier: id`.
- [x] 4.10 `Server.swift:989` (outer `handleToolCall` catch) — replace `return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)` with `let sanitized = EventKitErrorSanitizer.sanitizeForResponse(error); return CallTool.Result(content: [.text("Error: \(sanitized.code)")], isError: true)`. Note: outer catch does NOT use `writeFailureLog` because there is no `handler`/`identifier` context at that level — direct `sanitizeForResponse` call instead.
- [x] 4.11 跑 `swift build` — confirm compile clean. Then `swift test` — confirm all 184 prior tests still PASS, plus 4–7 new sanitizer tests = 188+ total.
- [x] 4.12 Final grep guard: `grep -rn "error\.localizedDescription" Sources/CheICalMCP/Server.swift Sources/CheICalMCP/EventKit/EventKitManager.swift` — only allowed remaining match is `EventKitManager.swift:1377` (covered by spec R3) and any non-catch-block usage. Catch blocks containing `error.localizedDescription = ...response field` MUST be zero. If grep returns more, audit and convert.

## 5. New unit tests for outer catch + writeFailureLog (TDD Red after Task 4)

- [x] 5.1 Add to `EventKitErrorSanitizerTests.swift` section `// MARK: - writeFailureLog`.
- [x] 5.2 `testWriteFailureLogReturnsSanitizedCode` — `let code = EventKitErrorSanitizer.writeFailureLog(handler: "h", identifier: "i", error: NSError(domain: EKErrorDomain, code: 7)); XCTAssertEqual(code, "eventkit_error_7")`. Stderr capture not required; the return-value contract is what's asserted.
- [x] 5.3 `testWriteFailureLogTrustedReturnsOriginalMessage` — `let code = EventKitErrorSanitizer.writeFailureLog(handler: "h", identifier: "i", error: ToolError.invalidParameter("foo")); XCTAssertEqual(code, "Invalid parameter: foo")`.
- [x] 5.4 (Optional) stderr capture test — pipe stderr through `dup2` for the duration of one call, assert captured bytes contain `"h(i) failed: ..."`. Mark as Optional in case `swift test` sandbox prevents reliable stderr capture; fallback is documenting that R7 stderr line is enforced by code review only.
- [x] 5.5 Add new file `Tests/CheICalMCPTests/OuterCatchDispatchTests.swift` for R8 coverage.
- [x] 5.6 `testOuterCatchToolErrorReturnsTrustedMessage` — server with empty fake; `try await server.executeToolCall(name: "unknown_tool", arguments: [:])`; capture the thrown ToolError's response by adapting how `handleToolCall` is exposed (see existing test patterns in `CleanupHandlerTests`); assert `CallTool.Result.content` contains `"Error: Unknown tool: unknown_tool"`.
- [x] 5.7 `testOuterCatchSanitizesNSError` — design choice: this requires a fake whose protocol method throws `NSError(domain: EKErrorDomain, code: 3)`. Use the existing `FakeEventKitManager.scriptListError(_:)` + `cleanup_completed_reminders` filter mode as the entry point. Assert `CallTool.Result.content` contains `"Error: eventkit_error_3"`.
- [x] 5.8 跑 `swift test --filter OuterCatchDispatchTests EventKitErrorSanitizerTests` — confirm 5.x all GREEN.
- [x] 5.9 跑 `swift test` 全套 — confirm no regression in 184 prior tests; expected total ≥ 190.

## 6. CHANGELOG + Spec updates + Follow-up filing

- [x] 6.1 In `CHANGELOG.md` `## [Unreleased]` `### Security` section (created in #32), add a sub-entry for #37: list the 10 sites converted, the new `TrustedErrorMessage` protocol, the new `sanitizeForResponse` API, and the `writeFailureLog` helper. Note that LOW-class sites' wire output is unchanged.
- [x] 6.2 Apply phase opens follow-up issues (one per uncovered handler) for destructive-primitive integration tests using FakeEventKitManager-equivalent seams. Expected follow-ups: `handleCreateEventsBatch`, `handleCreateRemindersBatch`, `handleDeleteEventsBatch`, `handleMoveEventsBatch`, similar-events lookup. Naming: `Add primitive-test seam for <handler> sanitizer wiring (follow-up of #37)`.
- [x] 6.3 Verify-time anti-pattern grep: `grep -rn "ToolError.invalidParameter.*localizedDescription\|EventKitError.*localizedDescription" Sources/` — confirm zero matches. If any author error type interpolates a framework `localizedDescription` into its own message, the trust contract is broken — file as P0 follow-up issue.

## 7. Design decision coverage map

- [x] 7.1 Design D1 'Empty marker protocol, not extending LocalizedError' — realized by Tasks 2.1, 3.1–3.5, 1.4 (negative case)
- [x] 7.2 Design D2 'Two-function API: sanitize unchanged, new sanitizeForResponse' — realized by Tasks 2.2, 5.6
- [x] 7.3 Design D3 'Helper writeFailureLog' — realized by Tasks 2.3, 4.1–4.9, 5.2–5.4
- [x] 7.4 Design D4 'Outer catch wire shape unchanged' — realized by Task 4.10 (preserves `"Error: \(...)"` shape)
- [x] 7.5 Design D5 'spec MODIFIED + ADDED delta, not new capability' — realized by `specs/eventkit-error-sanitization/spec.md` structure
- [x] 7.6 Design D6 'Test scope: unit covered, integration only where seam exists' — realized by 5.x scope + Task 6.2 follow-ups

## 8. Verification entry

- [x] 8.1 跑 `swift test` 全綠（預期 190+ tests）.
- [x] 8.2 跑 `swift build -c release` 清晰.
- [x] 8.3 commit 1: `feat: TrustedErrorMessage marker + sanitizeForResponse + writeFailureLog (#37)` — sanitizer extension + 3 author conformances (Tasks 2, 3) + new unit tests (Tasks 1, 5.1–5.4).
- [x] 8.4 commit 2: `refactor: route 10 leak sites through writeFailureLog (#37)` — Tasks 4.x.
- [x] 8.5 commit 3: `test: outer-catch dispatch + CHANGELOG + spec sync (#37)` — Tasks 5.5–5.9, 6.1, 6.3.
- [x] 8.6 commit 訊息全部用 `(#37)` suffix; 不用 `Closes` / `Fixes` / `Resolves` trailer (per `common-git-workflow` + `idd-implement` 鐵律).
- [x] 8.7 準備進 `/idd-verify #37`.
