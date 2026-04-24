import Foundation

// MARK: - Cleanup argument guards
//
// Pure validation helpers for the cleanup_completed_reminders tool.
// Kept as a standalone namespace so the argument invariants can be exercised
// by unit tests without wiring up a full MCP server.

enum ReminderCleanup {

    /// Reject `calendar_source` when `calendar_name` is absent.
    ///
    /// Rationale: the shared `listReminders(calendarName:calendarSource:)`
    /// primitive resolves the `calendars:` EventKit predicate ONLY when
    /// `calendarName` is non-nil (see `EventKitManager.swift:971-973`).
    /// If `calendarSource` is supplied alone, it is silently discarded and
    /// the cleanup widens to every calendar on every account. For a
    /// destructive, no-undo tool this is a destructive silent failure
    /// (Devil's Advocate §1 on #21 verification). Fail loudly at the
    /// handler boundary instead of propagating the ambiguity.
    static func rejectSourceWithoutName(name: String?, source: String?) throws {
        if name == nil && source != nil {
            throw ToolError.invalidParameter(
                "calendar_source requires calendar_name. To clean up a whole account, this tool does not support source-only scoping; omit calendar_source to clean all lists, or specify both."
            )
        }
    }
}
