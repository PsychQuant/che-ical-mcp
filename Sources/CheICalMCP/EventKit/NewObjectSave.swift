import EventKit

/// #261: saves an object that has never been written and, when the save fails, takes it back out
/// of the store unless a store made after the failure finds it. Behind closures (the
/// closure-seam variant, #182), so the order is tested without EventKit.
///
/// Found is success: when a new store finds the object after the save threw, the save committed,
/// so the object is kept and `run` returns. Every caller then goes on as after a save:
/// `create_reminder` returns the reminder and records its undo entry, `create_calendar` returns
/// the list, delete-undo reports the restore and consumes its record, and each marks the store
/// for a refresh.
///
/// Not found is a discard: the caller is told the save failed, and taking the object out keeps
/// the store consistent with that answer. Left in, it would be written by the next save of any
/// tool with no undo record (#261); a retry of delete-undo would also recreate it a second time
/// (`create_reminder` and `create_calendar` first look for an item with the same title in the
/// same list or of the same type, and return it).
///
/// No answer (the new store has no sources) is discarded too. This is the one exception to the
/// #261 rule "no defensive discard without probe evidence", tracked in #289: nothing shows that
/// such a save did not commit. Grounds: the caller has already been told the save failed; on
/// device a new store had no sources only with about ten stores that have read their sources
/// alive in one process, while the server keeps one such store (`EventKitManager`; the store
/// made at startup only reads the authorization status) plus the one this check makes and
/// releases; and with a long-lived store alive every check answered, up to 100 in a row in one
/// process, 280 over four runs.
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
///   about 30 ms). It also found each of 4 objects saved through this helper whose save returned
///   and then had a throw added by hand: their identifiers were already the saved ones. They were
///   left in place and kept by the next save. A store made while about ten others that have read
///   their sources are alive in the process has no sources and finds nothing: `freshStoreFinds`
///   then gives no answer, and the object is discarded (`unchecked`). The check's own stores are
///   released: with a long-lived store alive, every check answered, up to 100 in a row in one
///   process, 280 over four runs, and 200 over two more runs with that store held alive
///   explicitly through the loop.
///
/// Refused by validation, with no induced failure: a reminder with no list (the save threw
/// EKErrorDomain 1) or a list with no source (EKErrorDomain 14) was not found by a new store.
/// Removing the reminder threw EKErrorDomain 6 every time (37 of 37: S10v, Gc ×6, H3 ×2, U ×4,
/// XV ×24; `isNothingPending`). Removing the list threw nothing (32 of 32: Gc ×6, H4 ×2, XV ×24),
/// so a removal of a list the store never took in is staged. After either, the first commit (the
/// eight kinds above, 3 runs each for each type, XV) succeeded, the refused object never appeared,
/// and nothing else checked was lost.
///
/// Events: a new event or event calendar was not written by later saves, in the failure classes
/// tried (target deleted elsewhere, an induced commit failure, invalid dates), so those sites do
/// not come here. `remove(event, span: .thisEvent, commit: false)` after a recurring event's
/// failed save made the next save fail (EKCADErrorDomain 1001) and lose what that save wrote.
///
/// Not covered (closed list):
/// - a real save that throws after the object reached the store. The 4 runs above threw only
///   after `save` returned. A throw inside `save`, after the commit but while the object may still
///   hold an identifier that is not the saved one, was not seen. If the check misses such an
///   object (no answer, a read behind the commit, or a lookup by an identifier that was never the
///   saved one), the discard deletes the saved object at the next write by any tool. For
///   `create_reminder`, a retry in between would find that reminder by its title and report it as
///   existing, and the staged removal would still delete it (read from the code, not tried).
/// - found is success on a bare identifier lookup: the new store's item is not compared with the
///   object (title, list, alarms, recurrence), so an object only partly written would count as
///   saved. The found branch is covered by closure tests only; no device run had a real throw
///   inside `save`.
/// - a reminder saved into a read-only list: not tried. Any removal error after a save error other
///   than the reminder-with-no-list refusal is reported as a failed discard.
/// - stores other than iCloud.
///
/// Every outcome is one line on stderr. The caller gets the save's error unless a new store finds
/// the object.
enum NewObjectSave {
    /// What `run` reports after a failed save, once, after the removal (if any) has run. A plain
    /// discard that succeeded after the new store did not find the object is not reported.
    enum Outcome {
        /// A store made after the failure found the object: the save committed, then threw. The
        /// object is kept and `run` returns, so the call succeeds.
        case committedThenThrew
        /// That store had no sources and could not answer; the object was removed anyway, and the
        /// removal ran without an error.
        case unchecked
        /// The save was the refusal seen before the store took the object in, and the removal threw
        /// the error that refusal gave (`isNothingPending`).
        case nothingPending
        /// The removal threw anything else: the object may still be written by the next save.
        case discardFailed(save: Error, discard: Error)
    }

    /// Whether a failed insert of this type stayed pending on device: reminders and reminder
    /// lists did, events and event calendars did not.
    static func keepsFailedInsert(_ type: EKEntityType) -> Bool {
        type == .reminder
    }

    /// Whether a store made now finds the object, or nil when that store has no sources and
    /// cannot answer. It shares nothing in memory with the store that saved, which finds its own
    /// pending insert. The store is released when the pool drains. `NewObjectSaveTests` pins this
    /// body: one new store, nothing else, and nil when it has no sources.
    static func freshStoreFinds(_ find: (EKEventStore) -> Bool) -> Bool? {
        autoreleasepool {
            let store = EKEventStore()
            return store.sources.isEmpty ? nil : find(store)
        }
    }

    /// The one pair seen on device for a save refused before the store took the object in: a
    /// reminder with no list (the save threw EKErrorDomain 1, `noCalendar`), whose removal threw
    /// EKErrorDomain 6, "The calendar is read only" (37 of 37). A list with no source
    /// (EKErrorDomain 14) was removed without an error (32 of 32), so it has no pair here. Code 6
    /// alone is not enough: a removal from a read-only list could throw it too (not tried), and
    /// that is a failed discard.
    static func isNothingPending(save: Error, discard: Error) -> Bool {
        let (save, discard) = (save as NSError, discard as NSError)
        return save.domain == EKErrorDomain && save.code == EKError.Code.noCalendar.rawValue
            && discard.domain == EKErrorDomain && discard.code == EKError.Code.calendarReadOnly.rawValue
    }

    /// Runs `save`. When it throws, asks `committed`. True reports `.committedThenThrew`, keeps
    /// the object and returns: the save committed, so the caller goes on as after a save. False
    /// or nil runs `discard` and then reports one outcome: `.unchecked` (nil, and the removal
    /// ran), `.nothingPending` or `.discardFailed`; then rethrows the save's error.
    static func run(save: () throws -> Void, committed: () -> Bool?, discard: () throws -> Void,
                    report: (Outcome) -> Void) throws {
        do {
            try save()
        } catch {
            let found = committed()
            if found == true {
                report(.committedThenThrew)
                return
            }
            do {
                try discard()
                if found == nil { report(.unchecked) }
            } catch let discardError {
                report(isNothingPending(save: error, discard: discardError)
                       ? .nothingPending : .discardFailed(save: error, discard: discardError))
            }
            throw error
        }
    }

    /// The stderr line for an outcome (without the newline; the caller escapes it). The errors of
    /// a failed discard are named by domain and code only.
    static func note(for outcome: Outcome, handler: String, identifier: String) -> String {
        let site = "\(handler)(\(identifier))"
        func code(_ error: Error) -> String { "\((error as NSError).domain) \((error as NSError).code)" }
        switch outcome {
        case .committedThenThrew:
            return "\(site): the save threw, but a new store finds the item, so it was saved; it is kept and the call succeeds"
        case .unchecked:
            return "\(site): the save threw and a new store could not be read, so whether it was saved is unknown; it was removed from the store without committing"
        case .nothingPending:
            return "\(site): the save was refused before the store took the item in; nothing to remove"
        case .discardFailed(let save, let discard):
            return "\(handler).discard(\(identifier)) failed: the save threw \(code(save)) and removing the item without committing threw \(code(discard)); the next save by any tool may write it"
        }
    }
}
