import Foundation
import MCP

// MARK: - Cleanup argument guards
//
// Pure validation helpers for the cleanup_completed_reminders tool.
// Kept as a standalone namespace so the argument invariants can be exercised
// by unit tests without wiring up a full MCP server.

enum ReminderCleanup {

    /// Reject `calendar_source` when `calendar_name` is absent or empty.
    ///
    /// Rationale: the shared `listReminders(calendarName:calendarSource:)`
    /// primitive resolves the `calendars:` EventKit predicate ONLY when
    /// `calendarName` is non-nil and findCalendars finds a match (see
    /// `EventKitManager.swift:971-973`). If `calendarSource` is supplied
    /// alone, it is silently discarded and the cleanup widens to every
    /// calendar on every account. For a destructive, no-undo tool this is
    /// a destructive silent failure (verification Round 1 F1).
    ///
    /// Round 2 found two bypasses of the original guard:
    /// - `name=""` + `source="iCloud"` passed because empty string ≠ nil,
    ///   only stopped by coincidental findCalendars throw (R2-F3).
    /// - Non-string JSON (`name: 123`) collapses to nil via `.stringValue`,
    ///   making the guard blind to a type-coerced widening (R2-F1, fixed
    ///   in the handler via `requireStringIfPresent`).
    ///
    /// Fail loudly at the handler boundary instead of propagating any
    /// ambiguity downstream.
    static func rejectSourceWithoutName(name: String?, source: String?) throws {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameIsMeaningful = (trimmedName?.isEmpty == false)
        if !nameIsMeaningful && source != nil {
            throw ToolError.invalidParameter(
                "calendar_source requires a non-empty calendar_name. To clean up a whole account, this tool does not support source-only scoping; omit calendar_source to clean all lists, or specify both."
            )
        }
    }

    /// Require a `String?` value for keys where type-coercion via
    /// `.stringValue` would silently widen the tool's effective scope.
    ///
    /// `Value.stringValue` returns nil for any non-`.string` case. For
    /// filter parameters like `calendar_name` / `calendar_source`, silent
    /// nil means "no filter" — which for a destructive tool is the worst
    /// possible default under malformed input. R2-F1 (Codex) demonstrated
    /// that `{"calendar_source": 123}` bypassed the Round 1 guard by
    /// collapsing to nil before the guard runs.
    static func requireStringIfPresent(_ arguments: [String: Value], key: String) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let s = raw.stringValue else {
            throw ToolError.invalidParameter("\(key) must be a string")
        }
        return s
    }
}
