/// #261: saves an object that has never been written, and takes it back out of the store when
/// the save fails. Behind closures (the closure-seam variant, #182), so the order is tested
/// without EventKit.
///
/// Checked on device (iCloud, 2026-10-07): when a new reminder's `save(_:commit: true)` or a new
/// reminder list's `saveCalendar(_:commit: true)` fails at commit time, the store keeps it
/// pending, and the next successful save by this process, from any tool, writes it.
/// `rollback()` on the object does not drop it; `remove(_:commit: false)` /
/// `removeCalendar(_:commit: false)` does, and the next save still succeeds.
///
/// A new event or event calendar needs no discard and does not come here: a failed save of one
/// drops every pending change, and `remove(event, span:, commit: false)` after a recurring
/// event's failed save made the next save fail (EKCADErrorDomain 1001) and lose what it saved.
enum NewObjectSave {
    /// Runs `save`; when it throws, runs `discard`, then rethrows the save's error. An error from
    /// `discard` (the store refuses to remove an object it never inserted, e.g. after a
    /// validation failure) goes to `logDiscardFailure` and does not replace the save's error.
    static func run<Value>(save: () throws -> Value, discard: () throws -> Void,
                           logDiscardFailure: (Error) -> Void) throws -> Value {
        do {
            return try save()
        } catch {
            do {
                try discard()
            } catch let discardError {
                logDiscardFailure(discardError)
            }
            throw error
        }
    }
}
