import EventKit

/// #261: saves an object that has never been written and, when the save fails, takes it back out
/// of the store unless a store made after the failure finds it. Behind closures (the
/// closure-seam variant, #182), so the order is tested without EventKit.
///
/// Checked on device, iCloud only (2026-10-07 and 08). The commit failures were induced: an event
/// was staged with `save(_:span:commit: false)` into a calendar deleted through a second store,
/// so the store's next commit failed. No failure arising in normal use made a reminder save fail
/// at commit time: a reminder saved into a list deleted elsewhere succeeded (#281), and one
/// refused by validation left nothing pending. Under the induced failure:
/// - a new reminder (`save(_:commit: true)`) or reminder list (`saveCalendar(_:commit: true)`)
///   stayed pending; once the staged event was removed, the next save wrote it. `rollback()` did
///   not drop it; `remove(_:commit: false)` / `removeCalendar(_:commit: false)` did. The first
///   commit after either discard, which also carried the removal of the staged event, succeeded
///   for each kind tried, 3 runs each: an event save, a recurring event save, an event delete, a
///   recurring event delete, a reminder save with an alarm and a recurrence, a reminder delete,
///   a reminder list rename and a new reminder list. The discarded reminder had a recurrence, a
///   relative and an absolute alarm, and a location alarm. Nothing else in the calendars and
///   lists checked was lost.
/// - a store made after the failure did not find the failed object (54 of 54), while the store
///   that saved it did. Such a store found each normally saved reminder and list (10 of 10,
///   about 30 ms), and each one saved through this helper with a throw added after a real
///   commit (4 of 4), which was then left in place and kept by the next save. A store made
///   while about ten others that have read their sources are alive in the process has no
///   sources and finds nothing: `freshStoreFinds` then gives no answer, and the object is
///   discarded (`unchecked`).
/// - a reminder refused by validation (no list) was not found, and removing it threw
///   EKErrorDomain 6 (`isNothingPending`, 10 of 10); a list refused the same way (no source) was
///   removed without an error (8 of 8). Nothing was pending in either case.
/// - a new event or event calendar was not written by later saves, in the failure classes tried
///   (target deleted elsewhere, an induced commit failure, invalid dates), so those sites do not
///   come here. `remove(event, span: .thisEvent, commit: false)` after a recurring event's
///   failed save made the next save fail (EKCADErrorDomain 1001) and lose what that save wrote.
///
/// Not seen: a real save that throws after the object reached the store (the 4 runs above added
/// the throw by hand). A new store should find such an object, and it is left in place. If that
/// check misses it (no answer, or a read that lags the commit), the discard deletes the saved
/// object at the next write by any tool.
/// Every outcome other than a plain discard is reported on stderr only; the caller gets the
/// save's error either way.
enum NewObjectSave {
    /// What `run` reports after a failed save. A discard that succeeded is not reported.
    enum Outcome {
        /// A store made after the failure found the object: the save committed, then threw. The
        /// object is left in place.
        case committedThenThrew
        /// That store had no sources and could not answer; the object is discarded anyway.
        case unchecked
        /// The removal threw EKErrorDomain 6, as it does for a reminder the store never took in.
        case nothingPending
        /// The removal threw anything else: the object may still be written by the next save.
        case discardFailed(Error)
    }

    /// Whether a failed insert of this type stayed pending on device: reminders and reminder
    /// lists did, events and event calendars did not.
    static func keepsFailedInsert(_ type: EKEntityType) -> Bool {
        type == .reminder
    }

    /// Whether a store made now finds the object, or nil when that store has no sources and
    /// cannot answer. It shares nothing in memory with the store that saved, which finds its own
    /// pending insert.
    static func freshStoreFinds(_ find: (EKEventStore) -> Bool) -> Bool? {
        autoreleasepool {
            let store = EKEventStore()
            return store.sources.isEmpty ? nil : find(store)
        }
    }

    /// The error removing a never-inserted reminder gave on device: EKErrorDomain 6, "The
    /// calendar is read only" (S10v, Gc ×3). A pending reminder whose removal threw the same
    /// error would be reported as nothing pending; no such case was seen.
    static func isNothingPending(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == EKErrorDomain && error.code == EKError.Code.calendarReadOnly.rawValue
    }

    /// Runs `save`. When it throws, asks `committed`: true reports `.committedThenThrew` and
    /// leaves the object; false or nil (nil reported as `.unchecked`) runs `discard`, which
    /// reports `.nothingPending` or `.discardFailed` if it throws. Then rethrows the save's error.
    static func run<Value>(save: () throws -> Value, committed: () -> Bool?, discard: () throws -> Void,
                           report: (Outcome) -> Void) throws -> Value {
        do {
            return try save()
        } catch {
            let found = committed()
            if found == true {
                report(.committedThenThrew)
            } else {
                if found == nil { report(.unchecked) }
                do {
                    try discard()
                } catch let discardError {
                    report(isNothingPending(discardError) ? .nothingPending : .discardFailed(discardError))
                }
            }
            throw error
        }
    }

    /// The stderr line for an outcome at `site` (`handler(identifier)`, already escaped). A failed
    /// discard has none here: it goes through the error sanitizer.
    static func note(for outcome: Outcome, at site: String) -> String? {
        switch outcome {
        case .committedThenThrew:
            return "\(site): the save threw, but a new store finds the item, so it was saved; it is left in place\n"
        case .unchecked:
            return "\(site): the save threw and a new store could not be read, so whether it was saved is unknown; it was removed from the store without committing\n"
        case .nothingPending:
            return "\(site): the save was refused before the store took the item in; nothing to remove\n"
        case .discardFailed:
            return nil
        }
    }
}
