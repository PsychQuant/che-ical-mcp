# eventkit-error-sanitization Specification

## Purpose

TBD - created by archiving change 'sanitize-eventkit-failure-errors'. Update Purpose after archive.

## Requirements

### Requirement: Error Sanitizer produces stable codes for NSError

The system SHALL provide a pure-function utility `EventKitErrorSanitizer.sanitize(_:)` that maps any Swift `Error` to a stable string code, with the following value domain:

- If the input is an `NSError` whose `domain` equals `EKErrorDomain`, the code SHALL be the literal string `"eventkit_error_"` concatenated with the decimal representation of `NSError.code`.
- If the input is any other `NSError`, the code SHALL be the literal string `"error_"`, concatenated with a slug of the domain (defined below), concatenated with `"_"`, concatenated with the decimal representation of `NSError.code`.
- If the input is a Swift `Error` that is not bridged as `NSError`, the code SHALL be exactly `"error_unknown"`.

The domain slug SHALL be computed as follows: take the substring of `NSError.domain` after the last `.` character (or the full domain if no `.` is present); lowercase every ASCII letter; replace every character that is not an ASCII letter or digit with `_`.

The sanitizer SHALL NOT read `NSError.userInfo`, `NSError.localizedDescription`, `NSError.localizedFailureReason`, `NSError.localizedRecoverySuggestion`, or any other field whose content is documented as potentially human-readable or framework-generated text.

#### Scenario: EventKit error uses eventkit_error_N format

- **WHEN** `sanitize(_:)` is called with `NSError(domain: EKErrorDomain, code: 3, userInfo: nil)`
- **THEN** the returned code equals `"eventkit_error_3"`

##### Example: Value mapping across domains

| Input NSError (domain, code) | Expected `code` |
| ---------------------------- | --------------- |
| (`EKErrorDomain`, 0) | `eventkit_error_0` |
| (`EKErrorDomain`, 3) | `eventkit_error_3` |
| (`EKErrorDomain`, 15) | `eventkit_error_15` |
| (`NSCocoaErrorDomain`, 256) | `error_nscocoaerrordomain_256` |
| (`com.apple.foundation`, 42) | `error_foundation_42` |
| (`NSPOSIXErrorDomain`, 1) | `error_nsposixerrordomain_1` |

#### Scenario: Non-NSError Swift error collapses to error_unknown

- **WHEN** `sanitize(_:)` is called with a Swift `enum` error that does not conform to `CustomNSError`
- **THEN** the returned code equals `"error_unknown"`

#### Scenario: userInfo is never inspected

- **GIVEN** an `NSError(domain: EKErrorDomain, code: 5, userInfo: [NSLocalizedDescriptionKey: "Buy groceries at Whole Foods", NSLocalizedFailureReasonErrorKey: "Apartment 4B notes leaked"])`
- **WHEN** `sanitize(_:)` is called
- **THEN** the returned code equals `"eventkit_error_5"`
- **AND** the returned code string SHALL NOT contain any substring of `"Buy groceries"`, `"Whole Foods"`, `"Apartment 4B"`, or `"notes leaked"`

---
### Requirement: Sanitizer returns raw log for operator diagnostics

`EventKitErrorSanitizer.sanitize(_:)` SHALL return a struct with two fields: `code: String` (the value defined above) and `rawLog: String`. The `rawLog` field SHALL equal `error.localizedDescription` exactly.

The `rawLog` value is intended only for stderr logging on the server process and SHALL NOT be placed into any value returned to an MCP client.

#### Scenario: rawLog preserves original localizedDescription for operator debug

- **GIVEN** an `NSError(domain: EKErrorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (EKErrorDomain error 3.)"])`
- **WHEN** `sanitize(_:)` is called
- **THEN** the returned `rawLog` equals `"The operation couldn't be completed. (EKErrorDomain error 3.)"`

---
### Requirement: deleteRemindersBatch catch block routes errors through the sanitizer

`EventKitManager.deleteRemindersBatch(identifiers:onlyCompleted:)` SHALL, in its `catch` block that handles `eventStore.remove(reminder:commit:)` failures, invoke `EventKitErrorSanitizer.sanitize(_:)` on the caught error. The method SHALL append the returned `code` as the second element of the `failures` tuple, and SHALL NOT append `error.localizedDescription` or any substring derived from it.

The method SHALL write the returned `rawLog` value to `FileHandle.standardError` in a single line of the form `"deleteRemindersBatch(<identifier>) failed: <rawLog>\n"` before appending to `failures`.

Pre-catch failure strings (`"Reminder not found"`, `"Reminder is no longer completed"`) are not affected by this requirement and SHALL continue to be appended literally.

#### Scenario: EventKit throw surfaces sanitized code in failures

- **GIVEN** `deleteRemindersBatch(identifiers: ["r1"], onlyCompleted: false)` where `eventStore.remove` throws `NSError(domain: EKErrorDomain, code: 3)`
- **WHEN** the method returns
- **THEN** the returned `BatchDeleteResult.failures` contains exactly one entry `(identifier: "r1", error: "eventkit_error_3")`

#### Scenario: Pre-catch invariants still use literal strings

- **GIVEN** `deleteRemindersBatch(identifiers: ["r1"], onlyCompleted: true)` where the reminder with id `r1` exists but has `isCompleted == false`
- **WHEN** the method returns
- **THEN** the returned `BatchDeleteResult.failures` contains exactly one entry `(identifier: "r1", error: "Reminder is no longer completed")`

---
### Requirement: cleanup_completed_reminders response reflects sanitized codes end-to-end

The `cleanup_completed_reminders` MCP tool handler SHALL, when invoked in binding mode with `dry_run: false`, pass `failures` tuples from `BatchDeleteResult` into the response `failures[]` array with the `error` field set equal to the tuple's second element. No additional transformation of the `error` string SHALL occur at the handler layer.

As a consequence of this requirement and the previous one, `failures[].error` in any response produced by `cleanup_completed_reminders` SHALL satisfy one of:

- Equal the literal string `"Reminder not found"`
- Equal the literal string `"Reminder is no longer completed"`
- Match the regular expression `^eventkit_error_[0-9]+$`
- Match the regular expression `^error_[a-z0-9_]+_[0-9]+$`
- Equal the literal string `"error_unknown"`

#### Scenario: End-to-end sanitized code reaches response

- **GIVEN** a `FakeEventKitManager` scripted to return `BatchDeleteResult(successCount: 0, failedCount: 1, failures: [("r1", "eventkit_error_3")])` for `deleteRemindersBatch`
- **AND** a `CheICalMCPServer` initialized with `reminderCleanupSource` = that fake
- **WHEN** the handler is called with `{"reminder_ids": ["r1"], "dry_run": false}`
- **THEN** the response `failures` array contains exactly one entry `{"reminder_id": "r1", "error": "eventkit_error_3"}`
