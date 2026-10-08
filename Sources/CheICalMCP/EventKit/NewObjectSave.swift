import EventKit

/// #261: saves an object that has never been written and, when the save fails, takes it back out
/// of the store unless a store made after the failure finds it. Behind closures (the
/// closure-seam variant, #182), so the order is tested without EventKit.
///
/// The new store's answer (`Found`) decides. Its copy is compared with the object as it was
/// written (`Fields`): for a reminder the title, list, notes, priority, completion, URL, start and
/// due date to the minute, the due date's time zone, and the number of alarms and of recurrence
/// rules; for a list the title and account.
/// - found as saved: the save committed, so the object is kept and `run` returns no names. Every
///   caller goes on as after a save: `create_reminder` returns the reminder and records its undo
///   entry, `create_calendar` returns the list, delete-undo reports the restore and consumes its
///   record, and each marks the store for a refresh.
/// - found, but some compared fields differ: the item counts as saved too, and `run` returns the
///   names of those fields. The caller goes on as above and names them: `store_differs` and a
///   `note` in a create's response (`responseFields`), a clause after the restore in delete-undo's
///   message (`undoSuffix`), repeated in a batch undo's message (`batchSuffix`). Names only, never
///   values. The difference may come from a partial write or from an edit made elsewhere between
///   the commit and the check (the only device case was the second: a rename through another
///   store); a partial write was not seen. Keeping the item, and its undo entry or the consumed
///   record, means a retry cannot make a second copy, and the caller has the item's identifier.
/// - not found: the object is discarded and the save's error rethrown. The caller is told the save
///   failed, and taking the object out keeps the store consistent with that answer. Left in, it
///   would be written by the next save of any tool with no undo record (#261), and a retried
///   delete-undo would recreate it a second time. A retried create goes through its duplicate
///   check: `create_reminder` looks for an incomplete reminder of the same title in the same list
///   whose due date agrees within a minute (or neither has one), `create_calendar` for a calendar
///   of the same title and type, and either returns what it finds. Whether those checks see an
///   item still pending was read from the code, not tried.
/// - no answer (the new store has no sources) is a discard too. This is the one exception to the
///   #261 rule "no defensive discard without probe evidence", tracked in #289: nothing shows that
///   such a save did not commit. Grounds: the caller has already been told the save failed; on
///   device a new store had no sources only with about ten stores that have read their sources
///   alive in one process, while the server keeps one such store (`EventKitManager`; the store
///   made at startup only reads the authorization status) plus the one this check makes and
///   releases; and with a long-lived store alive every check answered: up to 100 in a row in one
///   process, 280 over four runs, and 200 more over two later runs in which that store was held
///   alive explicitly through the loop and read after it. The exception assumes that a failing
///   save and a new store without sources are unrelated; nothing on device shows that (a save
///   broken by a lost connection to the calendar daemon might also leave a new store without
///   sources).
///
/// Checked on device, iCloud only, in the host's time zone (+08:00), 2026-10-07 and 08. The commit
/// failures were induced: an event was staged with `save(_:span:commit: false)` into a calendar
/// deleted through a second store, so the store's next commit failed. No failure arising in normal
/// use made a reminder save fail at commit time: a reminder saved into a list deleted elsewhere
/// succeeded (#281), and one refused by validation left nothing pending. Under the induced failure:
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
///   about 30 ms). A store made while about ten others that have read their sources are alive in
///   the process has no sources and finds nothing: `freshStoreFinds` then gives no answer, and the
///   object is discarded (`unchecked`). The check's own stores are released (the counts above).
///
/// The comparison, on device, by run:
/// - 2026-10-08 05:22, before any comparison (identifier only): 4 objects saved through this
///   helper with a throw added after `save` returned were found and kept.
/// - 08:40, comparing the title, list and due date: clean saves of 4 reminder shapes and a list
///   compared as saved (5 of 5); saved with a throw added after `save` returned, the same 5 were
///   found as saved, and the saving store's copy of each reminder reported `isNew` and
///   `hasChanges` false (4 of 4 reminders; the list's copy was not examined); renamed through a
///   second store after the commit, then thrown, 2 reminders and 1 list were found differing in
///   their title.
/// - 09:10, comparing every field above: clean saves of 8 reminder shapes and a list compared as
///   saved with no names (9 of 9). The shapes: no due date; a zoned due with a recurrence and a
///   relative, an absolute and a location alarm; a date-only due; a floating timed due; notes,
///   priority, URL, a timed start, a zoned due, an alarm and an every-other-week rule; completed,
///   with a completion date; a date-only start written before a zoned due; a title and notes with
///   leading and trailing spaces and a newline. Saved with a throw added after `save` returned,
///   all 9 were found as saved with no names and the call succeeded; the saving store's copy of
///   each reminder was clean (8 of 8 reminders), the next saves succeeded (12 of 12), and a
///   separate process saw no item twice. Renamed through a second store after the commit, then
///   thrown, 2 reminders and 1 list were found differing in their title only, kept, and the call
///   succeeded with that name.
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
/// Written but not compared. This is a closed list: these are the only fields that
/// `createReminder`, `createCalendar` or `ReminderSnapshot.apply` writes and `Fields` leaves out;
/// do not read any other field into it or out of it, and a field those writes gain goes into
/// `Fields` or into this list.
/// - a reminder: (1) the completion date (only whether it is completed); (2) what each alarm holds:
///   its offset or date, its location (title, coordinates, radius), proximity, sound and email
///   (only how many alarms there are); (3) what each recurrence rule holds: frequency, interval,
///   end, days, months, set positions and week start (only how many rules there are); (4) the
///   start date's time zone and the reminder's own time zone; (5) seconds and smaller units of
///   the start and due date, and whether a start at 00:00 had a time (a date-only start reads
///   back as 00:00, so the two compare equal); (6) the calendar system of the date components.
/// - a list: (1) its color; (2) its type (a reminder list, fixed when it is made).
///
/// Not covered (closed list):
/// - a real throw inside `save`. Every device run threw only after `save` returned, when the
///   saving store's copy was already clean. A throw inside `save` may leave that copy unverified
///   and pending, to be written again by the next save. If the check misses an object that was
///   saved (no answer, a read behind the commit, or a lookup by an identifier that was never the
///   saved one), the discard deletes it at the next write by any tool; a `create_reminder` retried
///   in between would find the reminder by its title and report it as existing, and the staged
///   removal would still delete it (read from the code, not tried).
/// - a store that hands a compared field back changed (other sources, other time zones, other
///   calendar systems, text the store normalizes): the call still succeeds, with that field named.
/// - a reminder saved into a read-only list: not tried. Any removal error after a save error other
///   than the reminder-with-no-list refusal is reported as a failed discard.
/// - stores other than iCloud.
///
/// Every outcome is one line on stderr; the lines for a found item and for a failed removal name
/// the save's error by domain and code. The caller gets the save's error unless a new store finds
/// the object.
enum NewObjectSave {
    /// What `run` reports after a failed save, once, after the removal (if any) has run. A plain
    /// discard that succeeded after the new store did not find the object is not reported.
    enum Outcome {
        /// A store made after the failure found the object as it was saved (`Found.saved`): the
        /// save committed, then threw. The object is kept and `run` returns, so the call succeeds.
        case committedThenThrew(save: Error)
        /// That store found an item under the identifier, but the named fields differ from the
        /// object (`Found.differs`): a partial write, or an edit made elsewhere between the commit
        /// and the check. The item is kept, `run` returns the names, and the call succeeds.
        case committedButDiffers(fields: [String], save: Error)
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

    /// What a store made after the failure holds under the object's identifier.
    enum Found: Equatable {
        /// An item whose compared fields (`Fields`) agree with the object: the save committed.
        case saved
        /// An item whose fields named here differ from the object.
        case differs([String])
        /// Nothing.
        case absent
    }

    /// The fields compared between the object and a new store's copy, by name. Values are
    /// compared, never printed: only the names reach stderr.
    struct Fields: Equatable {
        let values: [String: String]

        init(_ values: [String: String]) {
            self.values = values
        }

        /// A reminder: what the save writes that reads back simply. Its title, list, notes,
        /// priority, completion, URL, start and due date to the minute, the due date's time zone,
        /// and how many alarms and recurrence rules it has. A date-only start reads as 00:00 of its
        /// day, which is how the store hands one back; a date-only due has no time.
        init(reminder: EKReminder) {
            func minute(_ date: DateComponents?, missing: String) -> String {
                date.map { [$0.year, $0.month, $0.day, $0.hour, $0.minute].map { $0.map(String.init) ?? missing }.joined(separator: " ") } ?? ""
            }
            self.init([
                "title": reminder.title ?? "",
                "list": reminder.calendar?.calendarIdentifier ?? "",
                "notes": reminder.notes ?? "",
                "priority": String(reminder.priority),
                "completion": reminder.isCompleted ? "completed" : "open",
                "url": reminder.url?.absoluteString ?? "",
                "start": minute(reminder.startDateComponents, missing: "0"),
                "due": minute(reminder.dueDateComponents, missing: "-"),
                "due time zone": reminder.dueDateComponents?.timeZone?.identifier ?? "",
                "alarm count": String(reminder.alarms?.count ?? 0),
                "recurrence rule count": String(reminder.recurrenceRules?.count ?? 0),
            ])
        }

        /// A reminder list: its title and its account (source).
        init(list: EKCalendar) {
            self.init(["title": list.title, "account": list.source?.sourceIdentifier ?? ""])
        }
    }

    /// `saved` when the new store's copy has the object's values, `differs` with every name
    /// whose value differs or is on one side only, `absent` when there is no copy.
    static func check(_ saved: Fields, against stored: Fields?) -> Found {
        guard let stored else { return .absent }
        let differing = Set(saved.values.keys).union(stored.values.keys).filter { saved.values[$0] != stored.values[$0] }
        return differing.isEmpty ? .saved : .differs(differing.sorted())
    }

    /// The check `saveNewReminder` hands `freshStoreFinds`: the item under the reminder's
    /// identifier, compared with the reminder as it was saved.
    static func reminderCheck(_ reminder: EKReminder) -> (EKEventStore) -> Found {
        { check(Fields(reminder: reminder), against: ($0.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder).map(Fields.init(reminder:))) }
    }

    /// The check `createCalendar` hands `freshStoreFinds` for a reminder list.
    static func listCheck(_ list: EKCalendar) -> (EKEventStore) -> Found {
        { check(Fields(list: list), against: $0.calendar(withIdentifier: list.calendarIdentifier).map(Fields.init(list:))) }
    }

    /// What a store made now holds, or nil when that store has no sources and cannot answer. It
    /// shares nothing in memory with the store that saved, which finds its own pending insert.
    /// The store is released when the pool drains. `NewObjectSaveTests` pins this body: one new
    /// store, no other store, and nil when it has no sources. The check reads the copy's compared
    /// fields (`Fields`, user content such as the title and notes); they stay in memory, and only
    /// the names of fields that differ leave it.
    static func freshStoreFinds(_ check: (EKEventStore) -> Found) -> Found? {
        autoreleasepool {
            let store = EKEventStore()
            return store.sources.isEmpty ? nil : check(store)
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

    /// Runs `save` and returns the names of compared fields the store holds differently from the
    /// object: none after a save that returned. When the save throws, asks `committed`. `.saved`
    /// reports `.committedThenThrew` and returns none; `.differs` reports `.committedButDiffers`
    /// and returns the names. Either way the object is kept and the caller goes on as after a
    /// save, telling its own caller about the names (`responseFields`, `undoSuffix`). `.absent`
    /// or nil runs `discard`, reports one outcome (`.unchecked` when nil and the removal ran,
    /// `.nothingPending` or `.discardFailed`), and rethrows the save's error.
    static func run(save: () throws -> Void, committed: () -> Found?, discard: () throws -> Void,
                    report: (Outcome) -> Void) throws -> [String] {
        do {
            try save()
            return []
        } catch {
            let found = committed()
            if found == .saved {
                report(.committedThenThrew(save: error))
                return []
            }
            if case .differs(let fields)? = found {
                report(.committedButDiffers(fields: fields, save: error))
                return fields
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

    /// The clause that tells the caller which compared fields the store holds differently, or nil
    /// when none: "the store holds a different due, title; check it". Names only, never values.
    static func storeDiffersClause(_ fields: [String]) -> String? {
        fields.isEmpty ? nil : "the store holds a different \(fields.joined(separator: ", ")); check it"
    }

    /// What a create response adds: `store_differs` (the names) and a `note`. Empty when none.
    static func responseFields(_ fields: [String]) -> [String: Any] {
        guard let clause = storeDiffersClause(fields) else { return [:] }
        return ["store_differs": fields, "note": "Saved, but \(clause)."]
    }

    /// What an undo message adds after the restored item: " — <clause>", or nothing.
    static func undoSuffix(_ fields: [String]) -> String {
        storeDiffersClause(fields).map { " — \($0)" } ?? ""
    }

    /// What a batch undo message adds: the members' messages that carry an `undoSuffix`, each
    /// after "; ". Nothing when none does.
    static func batchSuffix(_ members: [String]) -> String {
        members.filter { $0.contains(" — the store holds a different ") }.map { "; \($0)" }.joined()
    }

    /// The stderr line for an outcome (without the newline; the caller escapes it). The errors of
    /// a failed discard are named by domain and code only.
    static func note(for outcome: Outcome, handler: String, identifier: String) -> String {
        let site = "\(handler)(\(identifier))"
        func code(_ error: Error) -> String { "\((error as NSError).domain) \((error as NSError).code)" }
        switch outcome {
        case .committedThenThrew(let save):
            return "\(site): the save threw \(code(save)), but a new store finds the item as it was saved, so it was saved; it is kept and the call succeeds"
        case .committedButDiffers(let fields, let save):
            return "\(site): the save threw \(code(save)), and a new store finds the item, but its \(fields.joined(separator: ", ")) differ from what was written (a partial write or an edit made elsewhere); it is kept and the call succeeds with a note naming them"
        case .unchecked:
            return "\(site): the save threw and a new store could not be read, so whether it was saved is unknown; it was removed from the store without committing"
        case .nothingPending:
            return "\(site): the save was refused before the store took the item in; nothing to remove"
        case .discardFailed(let save, let discard):
            return "\(handler).discard(\(identifier)) failed: the save threw \(code(save)) and removing the item without committing threw \(code(discard)); the next save by any tool may write it"
        }
    }
}
