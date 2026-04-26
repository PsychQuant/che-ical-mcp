## MODIFIED Requirements

### Requirement: cleanup_completed_reminders response reflects sanitized codes end-to-end

The `cleanup_completed_reminders` MCP tool handler SHALL, when invoked in binding mode with `dry_run: false`, pass `failures` tuples from `BatchDeleteResult` into the response `failures[]` array with the `error` field set equal to the tuple's second element. No additional transformation of the `error` string SHALL occur at the handler layer.

As a consequence of this requirement and "deleteRemindersBatch catch block routes errors through the sanitizer", `failures[].error` in any response produced by `cleanup_completed_reminders` SHALL satisfy one of:

- Equal the literal string `"Reminder not found"`
- Equal the literal string `"Reminder is no longer completed"`
- Match the regular expression `^eventkit_error_[0-9]+$`
- Match the regular expression `^error_[a-z0-9_]+_[0-9]+$`
- Equal the literal string `"error_unknown"`

This invariant applies to the `sanitize(_:)` API only. Other MCP tool handlers that consume `sanitizeForResponse(_:)` (defined in a later requirement) accept a broader value domain that includes verbatim trusted-author messages, and are not bound by this regex.

#### Scenario: End-to-end sanitized code reaches response

- **GIVEN** a `FakeEventKitManager` scripted to return `BatchDeleteResult(successCount: 0, failedCount: 1, failures: [("r1", "eventkit_error_3")])` for `deleteRemindersBatch`
- **AND** a `CheICalMCPServer` initialized with `reminderCleanupSource` = that fake
- **WHEN** the handler is called with `{"reminder_ids": ["r1"], "dry_run": false}`
- **THEN** the response `failures` array contains exactly one entry `{"reminder_id": "r1", "error": "eventkit_error_3"}`

## ADDED Requirements

### Requirement: TrustedErrorMessage marker protocol opts a Swift error type into pass-through dispatch

The system SHALL provide a public empty marker protocol named `TrustedErrorMessage` declared in the same module as `EventKitErrorSanitizer`. The protocol SHALL declare zero method, property, or associated-type requirements.

A Swift `Error` type's conformance to `TrustedErrorMessage` is an explicit assertion by the type's author that the value of `errorDescription` (from `LocalizedError` conformance) or `localizedDescription` (from default `Error` bridging) is safe to forward verbatim to MCP clients without sanitization. Specifically, an author who marks a type with this protocol SHALL ensure the type's error description does not interpolate any framework-produced text whose content the author does not control.

The system SHALL declare the following existing types as conforming to `TrustedErrorMessage`:

- `ToolError` (defined in the MCP server source)
- `EventKitError` (defined in the EventKit manager source)
- `CLIError` (defined in the CLI runner source)

The system SHALL NOT declare any of the following Foundation framework types as conforming, because their error descriptions are produced by Apple frameworks and may carry locale-dependent or user-content-derived strings: `URLError`, `CocoaError` (`NSCocoaErrorDomain`), `POSIXError` (`NSPOSIXErrorDomain`), or any direct `NSError`.

#### Scenario: ToolError is trusted

- **WHEN** the runtime evaluates `ToolError.invalidParameter("title is required") is TrustedErrorMessage`
- **THEN** the result is `true`

#### Scenario: NSError from EKErrorDomain is not trusted

- **WHEN** the runtime evaluates `(NSError(domain: EKErrorDomain, code: 3) as Error) is TrustedErrorMessage`
- **THEN** the result is `false`

#### Scenario: Foundation Swift errors are not trusted by default

- **WHEN** the runtime evaluates `(URLError(.notConnectedToInternet) as Error) is TrustedErrorMessage`
- **THEN** the result is `false`

### Requirement: sanitizeForResponse dispatches by trust marker

The system SHALL provide a static function `EventKitErrorSanitizer.sanitizeForResponse(_:) -> SanitizedError`. The function SHALL behave as follows:

- If the input error is `TrustedErrorMessage` (i.e. `error is TrustedErrorMessage` evaluates `true`), the returned `SanitizedError` SHALL have both `code` and `rawLog` set equal to `error.localizedDescription`.
- Otherwise, the returned `SanitizedError` SHALL be exactly the value that `EventKitErrorSanitizer.sanitize(_:)` returns for the same input.

The function SHALL NOT mutate global state, perform I/O, or read any field of the error other than `localizedDescription` (in the trusted branch) or those fields read by `sanitize(_:)` (in the framework branch).

#### Scenario: Trusted error passes through unmodified

- **GIVEN** `let err: any Error = ToolError.invalidParameter("title is required")`
- **WHEN** `EventKitErrorSanitizer.sanitizeForResponse(err)` is called
- **THEN** the returned `code` equals `"Invalid parameter: title is required"`
- **AND** the returned `rawLog` equals `"Invalid parameter: title is required"`

#### Scenario: Framework error sanitizes via sanitize

- **GIVEN** `let err: any Error = NSError(domain: EKErrorDomain, code: 3, userInfo: nil)`
- **WHEN** `EventKitErrorSanitizer.sanitizeForResponse(err)` is called
- **THEN** the returned `code` equals `"eventkit_error_3"`
- **AND** the returned value equals `EventKitErrorSanitizer.sanitize(err)` exactly

#### Scenario: Foundation LocalizedError without TrustedErrorMessage takes framework branch

- **GIVEN** `let err: any Error = URLError(.notConnectedToInternet)`
- **WHEN** `EventKitErrorSanitizer.sanitizeForResponse(err)` is called
- **THEN** the returned `code` matches the regular expression `^error_[a-z0-9_]+_[0-9]+$`
- **AND** the returned `code` does NOT equal `URLError(.notConnectedToInternet).localizedDescription`

### Requirement: writeFailureLog combines stderr write with sanitization

The system SHALL provide a static function `EventKitErrorSanitizer.writeFailureLog(handler:identifier:error:) -> String`. The function SHALL:

- Compute `let sanitized = sanitizeForResponse(error)`.
- Write the line `"<handler>(<identifier>) failed: <sanitized.rawLog>\n"` to `FileHandle.standardError`. The literal characters `(` and `)` and `:` SHALL appear as shown.
- Return `sanitized.code`.

Callers SHALL use this function in any catch block that previously assigned `error.localizedDescription` directly into an MCP response field, except for the catch block specified in "deleteRemindersBatch catch block routes errors through the sanitizer", which continues to use `sanitize(_:)` directly per its own requirement.

#### Scenario: writeFailureLog returns sanitized code and writes raw log

- **GIVEN** `let err = NSError(domain: EKErrorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: "X"])`
- **WHEN** `let code = EventKitErrorSanitizer.writeFailureLog(handler: "createEventsBatch", identifier: "0", error: err)` is called
- **THEN** the returned `code` equals `"eventkit_error_3"`
- **AND** stderr contains the substring `"createEventsBatch(0) failed: X\n"`

#### Scenario: writeFailureLog with trusted error preserves message

- **GIVEN** `let err = ToolError.invalidParameter("start_date is required")`
- **WHEN** `let code = EventKitErrorSanitizer.writeFailureLog(handler: "createEventsBatch", identifier: "0", error: err)` is called
- **THEN** the returned `code` equals `"Invalid parameter: start_date is required"`

### Requirement: Outer handleToolCall catch routes through sanitizeForResponse

The outer `catch` block of `CheICalMCPServer.handleToolCall` (located at `Sources/CheICalMCP/Server.swift` line 989 at the time of this requirement) SHALL produce its `CallTool.Result` by:

- Calling `EventKitErrorSanitizer.sanitizeForResponse(error)` on the caught error.
- Returning `CallTool.Result(content: [.text("Error: \(sanitized.code)")], isError: true)`.

The block SHALL NOT pass `error.localizedDescription` (or any substring derived from it) directly into the returned `text` content, except via the trusted-pass-through branch of `sanitizeForResponse`.

The wire shape `"Error: <text>"` SHALL remain unchanged from prior behavior to avoid a breaking change for MCP clients that display the text verbatim.

#### Scenario: ToolError surfaces verbatim through outer catch

- **GIVEN** an MCP tool invocation that causes `handleToolCall` to throw `ToolError.invalidParameter("limit must be an integer")`
- **WHEN** the outer catch block runs
- **THEN** the returned `CallTool.Result.content` contains exactly one `.text` element with content `"Error: Invalid parameter: limit must be an integer"`
- **AND** `CallTool.Result.isError` equals `true`

#### Scenario: Apple NSError is sanitized through outer catch

- **GIVEN** an MCP tool invocation that causes `handleToolCall` to propagate `NSError(domain: EKErrorDomain, code: 3)` (not wrapped in any `TrustedErrorMessage` type)
- **WHEN** the outer catch block runs
- **THEN** the returned `CallTool.Result.content` contains exactly one `.text` element with content `"Error: eventkit_error_3"`
- **AND** `CallTool.Result.isError` equals `true`

### Requirement: Affected non-cleanup catch blocks dispatch via writeFailureLog

Each of the following catch blocks SHALL invoke `EventKitErrorSanitizer.writeFailureLog(handler:identifier:error:)` and assign its return value into the surrounding response field where the previous code assigned `error.localizedDescription`:

- `Sources/CheICalMCP/EventKit/EventKitManager.swift` `deleteEventsBatch(items:span:)` per-item catch (currently the only `localizedDescription`-leaking catch in `EventKitManager`'s event-batch path).
- `Sources/CheICalMCP/Server.swift` `handleCreateEventsBatch` per-item catches that previously surfaced parser or framework errors into `results[].error` (three call sites at the time of this requirement).
- `Sources/CheICalMCP/Server.swift` `handleCreateEventsBatch` similar-events lookup catch (one call site).
- `Sources/CheICalMCP/Server.swift` `handleCreateRemindersBatch` per-item catch that previously surfaced framework errors into `results[].error` (one call site).
- `Sources/CheICalMCP/Server.swift` `handleDeleteEventsBatch` per-item catch that previously surfaced framework errors into `failures[].error` (one call site).
- `Sources/CheICalMCP/Server.swift` `handleDeleteEventsBatch` dry-run preview catch that previously surfaced framework errors into `preview[].error` (one call site).
- `Sources/CheICalMCP/Server.swift` per-handler error surface that previously surfaced parser errors into `results[].error` (one call site).

After this requirement is applied, no batch-handler catch block in the named files SHALL contain the textual pattern `error.localizedDescription` as the right-hand side of an assignment to a response field. Stderr-only logging via `error.localizedDescription` outside of catch blocks (e.g. CLIRunner status output) is not affected by this requirement.

#### Scenario: deleteEventsBatch catch path uses writeFailureLog

- **GIVEN** `EventKitManager.deleteEventsBatch` whose `eventStore.remove` throws `NSError(domain: EKErrorDomain, code: 7)` for an item
- **WHEN** the method returns
- **THEN** the returned `BatchDeleteResult.failures` contains an entry whose `error` second element equals `"eventkit_error_7"`
- **AND** stderr contains the substring `"deleteEventsBatch(<identifier>) failed: "` where `<identifier>` is the input item's identifier

#### Scenario: handleCreateEventsBatch trusted-error path preserves original message

- **GIVEN** `handleCreateEventsBatch` invoked with an event payload whose `start_date` value is unparseable
- **AND** `parseFlexibleDate` throws `ToolError.invalidParameter("start_date 'foo' is not a recognized format")`
- **WHEN** the catch block runs
- **THEN** the resulting `results[]` array contains an entry whose `error` field equals `"Invalid parameter: start_date 'foo' is not a recognized format"`
