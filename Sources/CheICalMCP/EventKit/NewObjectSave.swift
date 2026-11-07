import CheMCPKit
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
///   names of those fields. The caller goes on as above and names them, always through
///   `differingFieldsNote`: `store_differs` and a `note` in a create's response
///   (`responseFields`), the note after the restore in delete-undo's message (`undoSuffix`, the
///   title shown through `undoShownTitle`, so it cannot close its quotes or start a line and the
///   real note is always outside them; inside its quotes a title can still read like the note,
///   and a literal U+2019 looks like a replaced quote), and in a batch undo one
///   entry per restored reminder with differing fields, the first five and then a count
///   (`UndoRestoredDifference.sentences`, which joins the entries itself, built from the names
///   `EventKitManager.restoreDeletedReminder` returns, never from message text). Names only, never
///   values. The difference may come from a partial write or from an edit made elsewhere between
///   the commit and the check (the only device case was the second: a rename through another
///   store); a partial write was not seen. The caller has the item's identifier and, for a
///   create, its undo entry. A retried delete-undo cannot make a second copy: a single undo's record is
///   consumed, and in a batch the member counts as restored and is left out of the entry that is
///   kept (#248). A retried create can: `create_reminder`'s duplicate check matches the title, list
///   and due date, and `create_calendar`'s the title and type, and the title, list or due date may
///   be among the differing fields, so the create note says that creating it again with the same
///   parameters may make a second copy.
/// - not found: the object is discarded and the save's error rethrown. The caller is told the save
///   failed, and taking the object out keeps the store consistent with that answer. Left in, it
///   would be written by the next save of any tool with no undo record (#261), and a retried
///   delete-undo would recreate it a second time. A retried create goes through its duplicate
///   check: `create_reminder` looks for an incomplete reminder of the same title in the same list
///   whose due date agrees within a minute (or neither has one), `create_calendar` for a calendar
///   of the same title and type, and either returns what it finds. Whether those checks see an
///   item still pending was read from the code, not tried.
/// - no answer (the new store has no sources): what happens is the caller's choice (`NoAnswer`,
///   #289, PR #421 round 1). A create keeps the object (`keep`): nothing shows that such a save did
///   not commit, a create has no undo record, and discarding a save that did commit would delete
///   the item at the next write by any tool with nothing to bring it back; #261's rule is "no
///   defensive discard without probe evidence". The cost is the other way round: an item whose
///   save did not commit stays pending and the next save of any tool writes it, a retry's own save
///   included, with no undo record; and an item that can never commit may make later saves in this
///   process fail until a restart (not tried). The saving store itself may see the pending item
///   (only a new store was seen not to): `list_calendars` may list a kept reminder list and a
///   retried `create_calendar` report it as existing (`isDuplicate`), with nothing saved (not
///   tried); a kept list is not left out of that duplicate check (PR #421 round 2: it would need
///   the manager to track kept items, for a branch never seen on device), and the message says so.
///   The caller gets `EventKitError.saveUnchecked`, which says what was kept, that a check right
///   away proves nothing, not to create it again until another save or a restart has settled it,
///   and that undo will not remove it. A restore
///   (`discard`; the undo of `delete_reminder`) removes the object as before #289: its undo record
///   is kept on failure, so a retry restores the reminder, while a kept pending copy would be
///   written by the next save and a retried undo would make a second one. The nil branch was not
///   produced on device (#289). Before #289 it was a discard everywhere, kept as the one exception
///   on these grounds: the caller has already been told the save failed; on
///   device a new store had no sources only with about ten stores that have read their sources
///   alive in one process, while the server keeps one such store (`EventKitManager`; the store
///   made at startup only reads the authorization status) plus the one this check makes and
///   releases; and with a long-lived store alive every check answered: up to 100 in a row in one
///   process, 280 over four runs, and 200 more over two later runs in which that store was held
///   alive explicitly through the loop and read after it. Those grounds assumed that a failing
///   save and a new store without sources are unrelated; nothing on device shows that (a save
///   broken by a lost connection to the calendar daemon might also leave a new store without
///   sources). They still describe how rare the branch is; on the restore path they still hold.
///
/// Checked on device, iCloud only, in the host's time zone (+08:00), 2026-10-07 and 08. The commit
/// failures were induced: an event was staged with `save(_:span:commit: false)` into a calendar
/// deleted through a second store, so the store's next commit failed. No failure arising in normal
/// use made a reminder save fail at commit time: a reminder saved into a list deleted elsewhere
/// returned without an error and wrote nothing (#281, below), and one refused by validation left
/// nothing pending. Under the induced failure:
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
///   the process has no sources and finds nothing: `freshStoreFinds` then gives no answer. Before
///   #289 the object was then discarded; now a create keeps it (`uncheckedKept`) and a restore
///   removes it (`unchecked`, `NoAnswer`). The check's own stores are released (the counts above).
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
///   priority 5, one URL (`https://example.com/che-ical-261`), a timed start, a zoned due, an
///   alarm and an every-other-week rule; completed, with a completion date; a date-only start
///   written first and a zoned due then set directly (in memory the due then reads floating, as it
///   does when a date-only start comes after it; delete-undo's own path, `writeZonedDue`, was not
///   run on device); a title and notes with leading and trailing spaces and a newline. Every other
///   shape had priority 0. All in the host's zone, Asia/Taipei (+08:00, no daylight saving), on
///   iCloud. Saved with a throw added after `save` returned,
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
///   (only how many alarms there are); (3) what each recurrence rule holds: its frequency,
///   interval, end (date or occurrence count), daysOfTheWeek (with week numbers), daysOfTheMonth,
///   daysOfTheYear, weeksOfTheYear, monthsOfTheYear, setPositions and firstDayOfTheWeek (only how
///   many rules there are); (4) the
///   start date's time zone and the reminder's own time zone; (5) seconds and smaller units of
///   the start and due date, and whether a start at 00:00 had a time (a date-only start reads
///   back as 00:00, so the two compare equal); (6) the calendar system of the date components.
/// - a list: (1) its color; (2) its type (a reminder list, fixed when it is made).
///
/// Not covered (closed list):
/// - a real throw inside `save`. Every device run threw only after `save` returned, when the
///   saving store's copy was already clean. A throw inside `save` may leave that copy unverified
///   and pending, to be written again by the next save. If the check misses an object that was
///   saved (a read behind the commit, a lookup by an identifier that was never the saved one, or no
///   answer on the restore path), the discard deletes it at the next write by any tool; a
///   `create_reminder` retried in between would find the reminder by its title and report it as
///   existing, and the staged removal would still delete it (read from the code, not tried). With
///   no answer, a create keeps it instead (#289).
/// - a store that hands a compared field back changed: the call still succeeds, with that field
///   named, a false note. Not tried, and so the likely sources of one: a time-zone alias (GMT and
///   UTC, Asia/Calcutta and Asia/Kolkata) or a zone the host does not use; a URL the store
///   normalizes (host case, a trailing slash, percent-encoding); priority values other than 0 and
///   5; another calendar system; text the store normalizes; sources other than iCloud.
/// - behaviour of the batch undo arm: its pins show its shape (each delete member through
///   `restoreDeletedReminder`, its names collected into an `UndoRestoredDifference`, which shows
///   the title through `undoShownTitle` itself, and `UndoRestoredDifference.sentences` from them),
///   not a run; pairing each member with its names is tested in `UndoBatchRestoreTests` with stub
///   restores. The `create_calendar` response's `store_differs` is tested from the
///   `CalendarWriteSource` seam out (#449); what fills it, in `createCalendar`, is pinned in source
///   only, since no seam fakes its store. A `create_reminders_batch` response's totals do not count rows that
///   carry a note.
/// - a reminder saved into a read-only list: not tried. Any removal error after a save error other
///   than the reminder-with-no-list refusal is reported as a failed discard.
/// - stores other than iCloud.
///
/// A save that returned but wrote nothing (#281): a reminder saved into a list that was deleted
/// through another store after the list was looked up. `save(_:commit: true)` returned without an
/// error and the reminder existed nowhere (a store made afterwards found nothing; on device,
/// iCloud, once on 2026-10-07 and 5 of 5 on 2026-11-05). Right after such a save, without any
/// refresh, the saving store read the list (`calendar(withIdentifier:)`) as nil (5 of 5) and the
/// reminder (`calendarItem(withIdentifier:)`) as nil (4 of 4, the runs that read it); after a
/// normal save it read both as present (1 of 1). So `saveNewReminder` passes `verified`, which
/// throws `ListDeletedDuringSave` only for that pair (`reminderWritten`). It reads the store as it
/// is and does not call `refreshSourcesIfNecessary`: the pair already read nil without one, and
/// nothing on device shows a refresh making a deletion visible that the store has not seen.
///
/// After such a save the same store saves normally (2026-11-05, iCloud, 2 of 2): a second reminder
/// into another list and an unrelated event, both saved and committed through the store whose
/// save wrote nothing, did not throw and were found by a store made afterwards, and the reminder
/// that was not written did not appear in any list, also after those later commits. Those saves
/// ran 15 to 17 ms after the deletion was committed through the other store; the earlier runs
/// saved right after it without timing.
///
/// Boundary: the check sees only what the saving store has seen. A deletion that store has not yet
/// seen when `verified` runs reads as a list that is still there, so the save is reported as created
/// (the #281 symptom, now only in that window). On device the store had seen the deletion every
/// time (above), and how late a deletion can become visible was not measured.
///
/// The shape needs the deletion to land between the list lookup and the save inside one call:
/// through the server, a list deleted elsewhere before a call was already gone when that call
/// looked it up (`create_reminder` refused with calendar-not-found right after the deletion and
/// 3 s later; a delete-undo refused with `undoListMissing`), since `findCalendar` reads the lists
/// live. The in-call race itself was not staged through the server (it needs a hook between the
/// lookup and the save). Not checked: other sources than iCloud, and a new reminder list saved
/// into a source deleted elsewhere (`createCalendar` passes no `verified`).
///
/// Every outcome of a failed save is one line on stderr; the lines for a found item, for no answer
/// and for a failed removal name the save's error by domain and code. The caller gets the save's
/// error unless a new store finds the object, or cannot answer on a create (then
/// `EventKitError.saveUnchecked`, #289). A save that returned and fails `verified` writes no stderr
/// line and runs no new store or removal: the caller gets `verified`'s error
/// (`ListDeletedDuringSave` for a reminder).
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
        /// That store had no sources and could not answer, on a path that discards then (a restore,
        /// whose undo record is kept for a retry; `NoAnswer.discard`): the object was removed, and the
        /// removal ran without an error.
        case unchecked(save: Error)
        /// That store could not answer, on a path that keeps the object then (a create, which has no
        /// undo record; `NoAnswer.keep`, #289): nothing was removed, and the caller gets
        /// `EventKitError.saveUnchecked`.
        case uncheckedKept(save: Error)
        /// The save was the refusal seen before the store took the object in, and the removal threw
        /// the error that refusal gave (`isNothingPending`).
        case nothingPending
        /// The removal threw anything else: the object may still be written by the next save.
        case discardFailed(save: Error, discard: Error)
    }

    /// What `run` does when the new store cannot answer (#289, PR #421 round 1), chosen by each
    /// caller:
    /// - `keep`, for a create (`create_reminder`, `create_reminders_batch`, `create_calendar`): no
    ///   undo record exists for it, so a removal of a save that did commit would delete the item at
    ///   the next write with nothing to bring it back. The item is kept and the caller gets
    ///   `EventKitError.saveUnchecked`.
    /// - `discard`, for a restore (the undo of `delete_reminder`, single and batch member): its undo
    ///   record is kept on failure, so a retry restores the reminder; keeping a pending copy there
    ///   would let the next save write it and a retried undo make a second one. As before #289.
    enum NoAnswer { case keep, discard }

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

    /// The names `Fields` compares, and so the only names a `store_differs` can hold: for a
    /// reminder, and for a reminder list. The tool descriptions list them (`ManifestParityTests`).
    static let reminderFieldNames = ["title", "list", "notes", "priority", "completion", "url", "start", "due",
                                     "due time zone", "alarm count", "recurrence rule count"]
    static let listFieldNames = ["title", "account"]

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
    /// object: none after a save that returned. A save that returned is then checked with
    /// `verified` (#281), which throws when nothing was written; its error leaves `run` with
    /// nothing else run (no new store, no discard, no report). When the save throws, asks
    /// `committed` (and never `verified`). `.saved`
    /// reports `.committedThenThrew` and returns none; `.differs` reports `.committedButDiffers`
    /// and returns the names. Either way the object is kept and the caller goes on as after a
    /// save, telling its own caller about the names (`responseFields`, `undoSuffix`). `.absent`
    /// runs `discard`, reports `.nothingPending` or `.discardFailed` when the removal throws, and
    /// rethrows the save's error. Nil (no answer) follows `onNoAnswer`: `.keep` runs no `discard`,
    /// reports `.uncheckedKept` and throws `EventKitError.saveUnchecked` with the save's sanitized
    /// code (#289); `.discard` does what `.absent` does, reporting `.unchecked` after a removal that
    /// ran without an error.
    static func run(save: () throws -> Void, verified: () throws -> Void = {}, committed: () -> Found?,
                    onNoAnswer: NoAnswer, discard: () throws -> Void, report: (Outcome) -> Void) throws -> [String] {
        do {
            try save()
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
            if found == nil, onNoAnswer == .keep {
                // #289: no evidence either way and no undo record, so nothing is removed.
                report(.uncheckedKept(save: error))
                throw EventKitError.saveUnchecked(code: EventKitErrorSanitizer.sanitize(error).code)
            }
            do {
                try discard()
                if found == nil { report(.unchecked(save: error)) }
            } catch let discardError {
                report(isNothingPending(save: error, discard: discardError)
                       ? .nothingPending : .discardFailed(save: error, discard: discardError))
            }
            throw error
        }
        try verified()
        return []
    }

    /// #281: whether a reminder whose save returned was written, from what the saving store reads
    /// right after it. Only a list that reads gone together with a reminder that does not resolve
    /// is "not written": the pair seen on device for a save into a list deleted elsewhere (4 of 4
    /// runs that read both), while a normal save read both present (1 of 1). Either one alone counts as written, so a
    /// transient read cannot turn a real save into a reported failure and a retry into a second copy.
    static func reminderWritten(listGone: Bool, itemResolves: Bool) -> Bool {
        !listGone || itemResolves
    }

    /// `saveNewReminder`'s `verified` check: throws `ListDeletedDuringSave` when
    /// `reminderWritten` says nothing was written. `restoring` picks the delete-undo wording.
    static func confirmWritten(listGone: Bool, itemResolves: Bool, restoring: Bool) throws {
        guard reminderWritten(listGone: listGone, itemResolves: itemResolves) else {
            throw ListDeletedDuringSave(restoring: restoring)
        }
    }

    /// #281: a reminder saved into a list that was deleted elsewhere between the list lookup and
    /// the save: the save returned and nothing was written. Author-written text with no list
    /// title, account or reminder title in it (#37). Not an `UnrecoverableUndoError`, so a
    /// delete-undo keeps its record (`UndoFailureDisposition.restore`, #191); the next undo then
    /// reads the lists first and refuses with `undoListMissing`, which says how to give it up.
    struct ListDeletedDuringSave: LocalizedError, TrustedErrorMessage, Equatable {
        let restoring: Bool

        var errorDescription: String? {
            restoring
                ? "Cannot undo the deletion of the reminder: its list was deleted while the reminder was being restored, so nothing was written and the history entry was kept. The next undo reports the list as unavailable and says how to give the entry up."
                : "The reminder list was deleted while the reminder was being saved; nothing was created."
        }
    }

    /// The one formatter for the note that names the compared fields the store holds differently,
    /// or nil when none: "the store holds a different due, title; check it". Names only, never
    /// values. Every caller builds its wording on it (`responseFields`, `undoSuffix`, and the batch
    /// undo's `UndoRestoredDifference.sentences`).
    static func differingFieldsNote(_ fields: [String]) -> String? {
        fields.isEmpty ? nil : "the store holds a different \(fields.joined(separator: ", ")); check it"
    }

    /// What a create response adds: `store_differs` (the names) and a `note`. Empty when none.
    /// The note warns that a retry may duplicate the item: `create_reminder`'s duplicate check
    /// matches the title, list and due date, and `create_calendar`'s the title and type, and the
    /// title, list or due date may be among the fields the store holds differently.
    static func responseFields(_ fields: [String]) -> [String: Any] {
        guard let note = differingFieldsNote(fields) else { return [:] }
        return ["store_differs": fields, "note": "Saved, but \(note). Creating it again with the same parameters may make a second copy."]
    }

    /// What a delete-undo message adds after the restore: " — <note>", or nothing.
    static func undoSuffix(_ fields: [String]) -> String {
        differingFieldsNote(fields).map { " — \($0)" } ?? ""
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
        case .unchecked(let save):
            return "\(site): the save threw \(code(save)) and a new store could not be read, so whether it was saved is unknown; it was removed from the store without committing (the undo record is kept for a retry)"
        case .uncheckedKept(let save):
            return "\(site): the save threw \(code(save)) and a new store could not be read, so whether it was saved is unknown; it was kept (not removed), since removing a save that committed would delete it at the next write (#289)"
        case .nothingPending:
            return "\(site): the save was refused before the store took the item in; nothing to remove"
        case .discardFailed(let save, let discard):
            return "\(handler).discard(\(identifier)) failed: the save threw \(code(save)) and removing the item without committing threw \(code(discard)); the next save by any tool may write it"
        }
    }
}
