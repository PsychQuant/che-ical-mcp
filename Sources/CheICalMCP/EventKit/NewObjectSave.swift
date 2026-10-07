import EventKit

/// #261: saves an object that has never been written, and takes it back out of the store when
/// the save failed after the store took it in. Behind closures (the closure-seam variant, #182),
/// so the order is tested without EventKit.
///
/// What was checked on device (iCloud only, 2026-10-07). The commit failures were induced: an
/// event was staged with `save(_:span:commit: false)` into a calendar deleted through a second
/// store, so the store's next commit failed. No production-shaped trigger made a reminder save
/// fail: a reminder saved into a list deleted elsewhere succeeded (#281), and one refused by
/// validation (no list) left nothing pending. Under the induced failure:
/// - a new reminder (`save(_:commit: true)`) or reminder list (`saveCalendar(_:commit: true)`)
///   stayed pending, and the next successful save wrote it. `rollback()` did not drop it;
///   `remove(_:commit: false)` / `removeCalendar(_:commit: false)` did. The next commit after
///   either discard was, in turn, an event save, a recurring event save, an event delete, a
///   reminder save with an alarm and a recurrence, and a reminder delete: each succeeded, and
///   nothing else in the calendars and lists checked was lost;
/// - after the failed save the object reported `isNew == false`; after a validation failure
///   (no list, no source), where nothing was pending, it reported `isNew == true`. `pending`
///   reads that, so a save refused before the store took the object in is not discarded (the
///   removal would throw, and its log line would look like a real discard failure);
/// - a new event or event calendar was not written by later saves, in the failure classes tried
///   (target deleted elsewhere, an induced commit failure, invalid dates), so those sites do not
///   come here. `remove(event, span: .thisEvent, commit: false)` after a recurring event's
///   failed save made the next save fail (EKCADErrorDomain 1001) and lose what it saved.
///
/// Not covered: a save that throws after the object reached the store (e.g. a sync error after
/// the commit). The discard would then remove it at the next save. No such failure was seen.
enum NewObjectSave {
    /// Whether a failed insert of this type stayed pending on device: reminders and reminder
    /// lists did, events and event calendars did not.
    static func keepsFailedInsert(_ type: EKEntityType) -> Bool {
        type == .reminder
    }

    /// Runs `save`; when it throws and `pending` reports that the store holds the object, runs
    /// `discard`, then rethrows the save's error. An error from `discard` goes to
    /// `logDiscardFailure` and does not replace the save's error.
    static func run<Value>(save: () throws -> Value, pending: () -> Bool, discard: () throws -> Void,
                           logDiscardFailure: (Error) -> Void) throws -> Value {
        do {
            return try save()
        } catch {
            if pending() {
                do {
                    try discard()
                } catch let discardError {
                    logDiscardFailure(discardError)
                }
            }
            throw error
        }
    }
}
