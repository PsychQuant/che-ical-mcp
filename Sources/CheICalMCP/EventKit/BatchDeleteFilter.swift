/// Pure-function predicates for batch-delete preflight filtering. Extracted
/// from `EventKitManager.deleteRemindersBatch` so the destructive contract
/// (#28 F1: binding mode rejects un-completed reminders mid-flight) is
/// testable without TCC / a real EventKit store. See #33 for the gap that
/// motivated this extraction.
enum BatchDeleteFilter {

    /// Returns `true` when a reminder should be **skipped** (added to
    /// `failures[]`) due to the `onlyCompleted` invariant — i.e. the caller
    /// asked for completed-only deletion but the reminder has been
    /// un-completed since the dry-run preview was issued.
    ///
    /// Pinned by `BatchDeleteFilterTests`. The 4-row truth table is the
    /// only authoritative description of the destructive contract; any
    /// future change to the skip rule MUST be reflected in this function
    /// or the production guard at `EventKitManager.deleteRemindersBatch`
    /// drifts away from #28 F1's promise.
    static func shouldSkipUncompleted(isCompleted: Bool, onlyCompleted: Bool) -> Bool {
        onlyCompleted && !isCompleted
    }
}
