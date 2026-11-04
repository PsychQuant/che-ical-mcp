import Foundation

/// #328: the narrow seam `delete_calendar` goes through (CLAUDE.md "Test Seam Convention"), so a
/// handler test can check what reaches the delete. Production passes nothing and gets
/// `EventKitManager.shared`.
protocol CalendarDeletionSource: Sendable {
    /// Deletes the calendar; with `requireEmpty`, refuses one that is not empty
    /// (`CalendarEmptiness.check`) and returns what was checked.
    func deleteCalendar(identifier: String, requireEmpty: Bool) async throws -> CalendarEmptiness.Checked?
}

extension EventKitManager: CalendarDeletionSource {}
