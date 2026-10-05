import CheMCPKit
import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #236: the completion and move checks, the order in which an undo target is resolved and
/// checked (`UndoTargetCheck`, the part of every undo arm that runs before the write), and the
/// errors a refusal produces. In memory only, so no TCC prompt.
final class UndoRefusalTests: XCTestCase {
    private let store = EKEventStore()
    private lazy var calendarA = EKCalendar(for: .event, eventStore: store)
    private lazy var calendarB = EKCalendar(for: .event, eventStore: store)
    private lazy var calendarC = EKCalendar(for: .event, eventStore: store)
    private lazy var list = EKCalendar(for: .reminder, eventStore: store)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func completedReminder(at date: Date) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = "Pay rent"
        reminder.isCompleted = true
        reminder.completionDate = date
        return reminder
    }

    private func completion(_ isCompleted: Bool, _ date: Date? = nil) -> UndoPostState.CompletionState {
        UndoPostState.CompletionState(isCompleted: isCompleted, completionDate: date)
    }

    // MARK: - Completion check

    func testCompletionCheckNamesTheFlagAndTheInstant() {
        let reminder = completedReminder(at: start)
        let check = { (expected: UndoPostState.CompletionState) in
            UndoPostState.reminderCompletion(id: "r", title: "Pay rent", state: expected, restoring: self.completion(false))
                .changedFields(in: reminder)
        }

        XCTAssertEqual(check(completion(true, start)), [])
        XCTAssertEqual(check(completion(true, start.addingTimeInterval(0.5))), [])
        XCTAssertEqual(check(completion(true)), [], "an unrecorded instant is not compared")
        XCTAssertEqual(check(completion(true, start.addingTimeInterval(120))), ["completion_date"])
    }

    /// verify #9: undo of complete_reminder after the reminder was unchecked by hand. The undo
    /// would write "incomplete", which is already the state: nothing to overwrite.
    func testCompletionUndoProceedsWhenUncheckedByHand() {
        let reminder = completedReminder(at: start)
        reminder.isCompleted = false

        let undo = UndoPostState.reminderCompletion(id: "r", title: "Pay rent", state: completion(true, start), restoring: completion(false))
        XCTAssertEqual(undo.changedFields(in: reminder), [])
    }

    /// Completed again at another time: the undo would replace that instant, so it refuses.
    func testCompletionIsComparedAsOneValue() {
        let reminder = completedReminder(at: start.addingTimeInterval(3600))
        let undoOfReopen = UndoPostState.reminderCompletion(id: "r", title: "Pay rent", state: completion(false),
                                                            restoring: completion(true, start))

        XCTAssertEqual(undoOfReopen.changedFields(in: reminder), ["completed"])
    }

    // MARK: - Move check

    func testMoveCheckComparesOnlyTheCalendar() {
        let event = EKEvent(eventStore: store)
        event.calendar = calendarB
        event.title = "Edited after the move"
        let undo = UndoPostState.eventCalendar(id: "e", title: "Review", calendarIdentifier: calendarB.calendarIdentifier,
                                               restoringCalendarIdentifier: calendarA.calendarIdentifier)

        XCTAssertEqual(undo.changedFields(in: event), [], "a move-undo writes only the calendar")
        event.calendar = calendarA
        XCTAssertEqual(undo.changedFields(in: event), [], "moved back by hand: nothing to overwrite (verify #9)")
        event.calendar = calendarC
        XCTAssertEqual(undo.changedFields(in: event), ["calendar"])
    }

    // MARK: - Resolve, refresh, check (verify #3)

    private let expected = UndoPostState.eventCalendar(id: "e", title: "Review", calendarIdentifier: "to",
                                                       restoringCalendarIdentifier: "from")

    func testAMissingTargetIsNotFoundAndNothingIsCompared() {
        var compared = false
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { nil as EKEvent? },
                                                       refresh: { _ in true },
                                                       conflicts: { _ in compared = true; return [] })) { error in
            XCTAssertTrue(error is UndoTargetMissingError, "\(error)")
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "not found keeps the record (#191, spec)")
        }
        XCTAssertFalse(compared)
    }

    func testATargetThatCannotBeRefreshedIsNotFound() {
        let event = EKEvent(eventStore: store)
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { event }, refresh: { _ in false },
                                                       conflicts: { _ in [] })) { error in
            XCTAssertTrue(error is UndoTargetMissingError, "\(error)")
        }
    }

    /// Refresh before compare: a long-lived store returns stale fields until the object is
    /// refreshed (diagnosis evidence 2, confirmed by the on-device probe).
    func testTheTargetIsRefreshedBeforeItIsCompared() throws {
        let event = EKEvent(eventStore: store)
        var steps: [String] = []
        let checked = try UndoTargetCheck.check(expected, verb: .undo,
                                                lookup: { steps.append("lookup"); return event },
                                                refresh: { _ in steps.append("refresh"); return true },
                                                conflicts: { _ in steps.append("compare"); return [] })

        XCTAssertEqual(steps, ["lookup", "refresh", "compare"])
        XCTAssertTrue(checked === event, "the arm writes to the object that was refreshed and compared")
    }

    func testConflictsRefuseWithTheChangedFields() {
        let event = EKEvent(eventStore: store)
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { event }, refresh: { _ in true },
                                                       conflicts: { _ in ["calendar"] })) { error in
            guard let changed = error as? UndoTargetChangedError else { return XCTFail("\(error)") }
            XCTAssertTrue(changed.message.contains("(calendar)"), changed.message)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        }
    }

    /// The update arm's recurring-target refusal is thrown from `conflicts`, after resolve and
    /// refresh and before the comparison; the seam passes it through unchanged (round 5).
    func testAnErrorFromTheConflictCheckPassesThrough() {
        let event = EKEvent(eventStore: store)
        var steps: [String] = []
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo,
                                                       lookup: { steps.append("lookup"); return event },
                                                       refresh: { _ in steps.append("refresh"); return true },
                                                       conflicts: { _ in throw UnrecoverableUndoError(message: "repeats now") })) { error in
            XCTAssertEqual((error as? UnrecoverableUndoError)?.message, "repeats now")
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        }
        XCTAssertEqual(steps, ["lookup", "refresh"])
    }

    func testAnArmCanSupplyItsOwnRefusal() {
        let event = EKEvent(eventStore: store)
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { event }, refresh: { _ in true },
                                                       conflicts: { _ in ["completed"] },
                                                       refusal: { _, _ in UnrecoverableUndoError(message: "custom") })) { error in
            XCTAssertEqual((error as? UnrecoverableUndoError)?.message, "custom")
        }
    }

    // MARK: - Recurring completion without an occurrence snapshot (round 2, findings 2, 8, 9, 13, 19, 21)

    /// `forCompletion` keeps a recurring completion without the #204 snapshot when the reminder
    /// had no due date or rules (`isIdentifiable` false); the record says it was recurring.
    private func legacyRecurring(was: Bool, requested: Bool) -> UndoOperation {
        .completeReminder(id: "r", wasCompleted: was, requestedCompleted: requested, completionDate: was ? start : nil,
                          title: "Daily", redoCompletionDate: requested ? start : nil, wasRecurring: true)
    }

    private func reminder(completed: Bool, at date: Date? = nil) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = "Daily"
        reminder.isCompleted = completed
        reminder.completionDate = date
        return reminder
    }

    /// After a rollover the identifier points at the next, incomplete occurrence. That equals
    /// what the undo writes, but matching the write is not identity: the record cannot confirm
    /// the occurrence, so the undo refuses instead of writing to the successor.
    func testRolloverUndoDoesNotWriteToTheSuccessor() throws {
        let op = legacyRecurring(was: false, requested: true)
        let successor = recurring(reminder(completed: false))

        XCTAssertEqual(try XCTUnwrap(op.undoPostState).changedFields(in: successor), ["completed"], "refused: nothing is written")
    }

    private func recurring(_ reminder: EKReminder) -> EKReminder {
        reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        return reminder
    }

    /// The successor shape: the identifier resolves to the same recurring reminder with the
    /// opposite completion of what the record left, which is what a rollover produces. Such a
    /// record can never match again, so it is discarded, as #204 does, and earlier operations stay
    /// undoable (round 3, finding 8).
    func testUndoInTheSuccessorShapeIsDiscarded() throws {
        let op = legacyRecurring(was: false, requested: true)
        let successor = recurring(reminder(completed: false))

        let fields = try XCTUnwrap(op.undoPostState).changedFields(in: successor)
        let error = op.postStateRefusal(verb: .undo, changedFields: fields, current: successor)
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.contains("discarded"), message)
        XCTAssertTrue(message.contains("earlier operations remain undoable"), message)
        XCTAssertFalse(message.contains("discard_id"), "nothing is left to discard")
        XCTAssertTrue(message.contains("complete_reminder"), message)
    }

    func testRedoInTheSuccessorShapeIsDiscarded() throws {
        let op = legacyRecurring(was: true, requested: false)
        let opposite = recurring(reminder(completed: false))

        let fields = try XCTUnwrap(op.redoPostState).changedFields(in: opposite)
        XCTAssertEqual(fields, ["completed"])
        let error = op.postStateRefusal(verb: .redo, changedFields: fields, current: opposite)
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        XCTAssertTrue(EventKitErrorSanitizer.sanitizeForResponse(error).code.hasPrefix("Cannot redo"))
    }

    /// Every other mismatch is refused and kept: the same flag at another instant, or a reminder
    /// that no longer repeats.
    func testOtherMismatchesOfAnUnconfirmedRecordAreKept() throws {
        let op = legacyRecurring(was: false, requested: true)
        let completedLater = recurring(reminder(completed: true, at: start.addingTimeInterval(3600)))
        let noLongerRecurring = reminder(completed: false)

        for item in [completedLater, noLongerRecurring] {
            let fields = try XCTUnwrap(op.undoPostState).changedFields(in: item)
            XCTAssertFalse(fields.isEmpty)
            let error = op.postStateRefusal(verb: .undo, changedFields: fields, current: item)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "kept: the spec keeps refused records")
            let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
            XCTAssertTrue(message.contains("later occurrence"), message)
            XCTAssertFalse(message.contains("change it back"), "there is no change to revert")
            XCTAssertTrue(message.contains("discard_id"), message)
        }
        let completedOnce = reminder(completed: true, at: start)
        let redoFields = try XCTUnwrap(op.redoPostState).changedFields(in: completedOnce)
        XCTAssertEqual(redoFields, ["completed"])
        XCTAssertEqual(UndoFailureDisposition.of(op.postStateRefusal(verb: .redo, changedFields: redoFields, current: completedOnce)), .restore)
    }

    /// Redo writes the request again; it too goes ahead only on the state the undo left, never on
    /// a reminder that merely already looks like what redo would write.
    func testRolloverRedoDoesNotWriteToTheSuccessor() throws {
        let op = legacyRecurring(was: false, requested: true)
        let alreadyLikeTheRedo = reminder(completed: true, at: start)

        XCTAssertEqual(try XCTUnwrap(op.redoPostState).changedFields(in: alreadyLikeTheRedo), ["completed"])
        XCTAssertEqual(try XCTUnwrap(op.redoPostState).changedFields(in: reminder(completed: false)), [], "the state the undo left")
    }

    /// The un-advanced case still works: the reminder is as the completion left it.
    func testUndoProceedsWhileTheReminderIsAsTheCompletionLeftIt() throws {
        let op = legacyRecurring(was: false, requested: true)
        XCTAssertEqual(try XCTUnwrap(op.undoPostState).changedFields(in: reminder(completed: true, at: start)), [])
    }

    /// The exemption stays for records of non-recurring reminders, where the identifier cannot
    /// move to another occurrence.
    func testANonRecurringRecordKeepsTheAlreadyRestoredExemption() throws {
        let op = UndoOperation.completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                                                title: "Once", redoCompletionDate: start, wasRecurring: false)
        XCTAssertEqual(try XCTUnwrap(op.undoPostState).changedFields(in: reminder(completed: false)), [], "unchecked by hand")
        let error = op.postStateRefusal(verb: .undo, changedFields: ["completed"], current: reminder(completed: false))
        XCTAssertFalse(EventKitErrorSanitizer.sanitizeForResponse(error).code.contains("later occurrence"))
    }

    /// The record decides, not the reminder's current rules (round 2, finding 9).
    func testForCompletionRecordsWhetherTheReminderWasRecurring() {
        let recurring = ReminderCompletionSnapshot(id: "r", title: "Daily", calendarID: "c", sourceID: "s", isCompleted: false,
                                                   hasRecurrence: true, due: nil, rules: [], completionDate: nil)
        guard case .completeReminder(_, _, _, _, _, _, let wasRecurring) = UndoOperation.forCompletion(
            before: recurring, requestedCompleted: true, savedTitle: "Daily", savedCompletionDate: start) else {
            return XCTFail("a recurring snapshot without due or rules keeps the legacy record")
        }
        XCTAssertTrue(wasRecurring)
    }

    func testOtherRefusalsKeepTheRecord() {
        let update = UndoOperation.updateReminder(id: "r", oldSnapshot: UndoSnapshotFixtures.reminder(), saved: UndoSnapshotFixtures.reminder())
        XCTAssertEqual(UndoFailureDisposition.of(update.postStateRefusal(verb: .undo, changedFields: ["title"], current: nil)), .restore)
    }

    // MARK: - Series create-undo (verify #1)

    /// The delete of a series removes every occurrence, so create-undo looks for occurrences
    /// edited elsewhere. EventKit matches at most four years per query; the scan covers the
    /// series from a day before its first occurrence to a day after its end, at most 1460 days.
    func testTheSeriesScanWindow() {
        let open = UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: nil)
        XCTAssertEqual(open.start, start.addingTimeInterval(-86_400))
        XCTAssertEqual(open.duration, 1460 * 86_400, "EventKit matches at most four years per query (round 2, finding 27)")

        let ending = UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: start.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(ending.end, start.addingTimeInterval(31 * 86_400))
    }

    /// On device (iCloud, 2026-10-05) an occurrence edited on its own reads back with its own
    /// identifier, the series identifier plus `/RID=<seconds>`, and deleting the series removes
    /// it too. Other stores may give it an unrelated identifier but keep the iCalendar UID, so the
    /// external identifier is accepted as well, equal or with the same suffix form (round 2,
    /// finding 4).
    func testAnEditedOccurrenceIsRecognisedByEitherIdentifier() {
        let series = UndoPostState.OccurrenceIDs(eventIdentifier: "29034CB8:098D5E80", externalIdentifier: "098D5E80")
        let match = { (id: String?, ext: String?) in
            UndoPostState.isOccurrence(UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: ext), of: series)
        }

        XCTAssertTrue(match("29034CB8:098D5E80", "098D5E80"))
        XCTAssertTrue(match("29034CB8:098D5E80/RID=815878800", "098D5E80/RID=815878800"), "iCloud shape")
        XCTAssertTrue(match("EXCHANGE-OCCURRENCE-7", "098D5E80"), "unrelated identifier, same UID")
        XCTAssertTrue(match("EXCHANGE-OCCURRENCE-7", "098D5E80/RID=815878800"))
        XCTAssertFalse(match("29034CB8:6384413B", "6384413B"))
        XCTAssertFalse(match("29034CB8:098D5E800", "098D5E800"), "a longer identifier is another item")
        XCTAssertFalse(match(nil, nil))
        XCTAssertFalse(UndoPostState.isOccurrence(UndoPostState.OccurrenceIDs(eventIdentifier: "x", externalIdentifier: ""),
                                                  of: UndoPostState.OccurrenceIDs(eventIdentifier: "y", externalIdentifier: "")),
                       "empty UIDs do not match each other")
    }

    // MARK: - Which detached occurrences count (round 3 finding 7, round 4 decision)

    /// An occurrence as the scan sees it: built in memory like the series' first occurrence (title,
    /// location, place without coordinates, a 15-minute alarm, Asia/Taipei), then `edit`ed. `slot`
    /// is its `occurrenceDate`; by default the start it ends up with.
    private func occurrence(slot: Date?? = nil, _ edit: (EKEvent) -> Void = { _ in }) -> UndoPostState.OccurrenceFace {
        let event = EKEvent(eventStore: store)
        event.calendar = calendarA
        event.title = "Standup"
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.structuredLocation = EKStructuredLocation(title: "Room 1")
        event.timeZone = TimeZone(identifier: "Asia/Taipei")
        event.addAlarm(EKAlarm(relativeOffset: -900))
        edit(event)
        return UndoPostState.OccurrenceFace(slot: slot ?? event.startDate, event: EventSnapshot(from: event, includeRecurrence: false))
    }

    /// The tool's own sequence before round 4 (an occurrence updated, then that update undone): the
    /// occurrence stays detached but holds the series' values again, so it is not an edit.
    func testAnOccurrenceBackAtTheSeriesValuesIsNotAnEdit() {
        let series = occurrence()
        XCTAssertTrue(UndoPostState.differsFromSeries(occurrence { $0.title = "Standup (moved talk)" }, series: series))
        XCTAssertFalse(UndoPostState.differsFromSeries(occurrence(), series: series))
    }

    /// Round 4 decision: an occurrence whose only edit is its alarm is an edit, so the create-undo
    /// of the series refuses instead of deleting it.
    func testAnAlarmOnlyEditBlocksTheCreateUndo() {
        let series = occurrence()
        let alarmOnly = occurrence { event in
            event.alarms?.forEach { event.removeAlarm($0) }
            event.addAlarm(EKAlarm(relativeOffset: -1800))
        }
        let counted = [alarmOnly].filter { UndoPostState.differsFromSeries($0, series: series) }.count
        XCTAssertEqual(UndoPostState.seriesConflicts(modifiedOccurrences: counted), ["modified_occurrences"])
    }

    /// Every field the guard compares counts on its own, with the guard's tolerances.
    func testWhatMakesAnOccurrenceDiffer() {
        let series = occurrence()
        let differs = { (face: UndoPostState.OccurrenceFace) in UndoPostState.differsFromSeries(face, series: series) }

        XCTAssertTrue(differs(occurrence(slot: .some(start)) { $0.startDate = self.start.addingTimeInterval(1800); $0.endDate = $0.startDate.addingTimeInterval(3600) }), "moved off its slot")
        XCTAssertTrue(differs(occurrence { $0.title = "Retro" }))
        XCTAssertTrue(differs(occurrence { $0.notes = "agenda" }))
        XCTAssertTrue(differs(occurrence { $0.url = URL(string: "https://example.com") }))
        XCTAssertTrue(differs(occurrence { $0.isAllDay = true }))
        XCTAssertTrue(differs(occurrence { $0.endDate = $0.startDate.addingTimeInterval(5400) }), "duration")
        XCTAssertTrue(differs(occurrence { $0.addAlarm(EKAlarm(relativeOffset: -3600)) }), "an alarm added")
        XCTAssertTrue(differs(occurrence { $0.timeZone = TimeZone(identifier: "Europe/Berlin") }), "time zone")
        XCTAssertTrue(differs(occurrence { $0.structuredLocation = EKStructuredLocation(title: "Room 2") }), "place")
        XCTAssertTrue(differs(occurrence(slot: .some(nil))), "no slot to compare with: counted, the side that refuses")

        XCTAssertFalse(differs(occurrence { $0.startDate = self.start.addingTimeInterval(7 * 86_400); $0.endDate = $0.startDate.addingTimeInterval(3600) }), "on its own slot a week later")
        XCTAssertFalse(differs(occurrence { $0.notes = "" }), "no notes and empty notes are the same")
        XCTAssertFalse(differs(occurrence(slot: .some(start)) { $0.startDate = self.start.addingTimeInterval(0.4); $0.endDate = $0.startDate.addingTimeInterval(3600) }), "to the second")
        XCTAssertFalse(differs(occurrence { $0.alarms?.first?.soundName = "Ping" }), "an alarm sound is not an edit")
        XCTAssertFalse(differs(occurrence { event in
            let place = EKStructuredLocation(title: "Room 1")
            place.geoLocation = CLLocation(latitude: 25.0434, longitude: 121.6145)
            event.structuredLocation = place
        }), "coordinates added to a place the series has without them are not an edit")
    }

    /// Round 5 findings 16, 26, 28: time zones compare by their offset at the occurrence's start,
    /// so two spellings of one zone are the same and a real change of zone still counts.
    func testTimeZonesCompareByOffsetAtTheOccurrence() {
        let series = occurrence()
        XCTAssertFalse(UndoPostState.differsFromSeries(occurrence { $0.timeZone = TimeZone(secondsFromGMT: 8 * 3600) }, series: series),
                       "GMT+8 and Asia/Taipei")
        XCTAssertTrue(UndoPostState.differsFromSeries(occurrence { $0.timeZone = TimeZone(identifier: "Asia/Tokyo") }, series: series))
        XCTAssertTrue(UndoPostState.differsFromSeries(occurrence { $0.timeZone = nil }, series: series), "floating is a change")

        let newYork = occurrence { $0.timeZone = TimeZone(identifier: "America/New_York") }
        XCTAssertTrue(UndoPostState.differsFromSeries(occurrence { $0.timeZone = TimeZone(identifier: "America/Bogota") }, series: newYork),
                      "the same offset in January (round 6), not after New York's next transition")
    }

    /// The place counts on its own: the same name moved to other coordinates.
    func testAPlaceMovedUnderTheSameNameIsAnEdit() {
        func at(_ latitude: Double) -> (EKEvent) -> Void {
            { event in
                let place = EKStructuredLocation(title: "Room 1")
                place.geoLocation = CLLocation(latitude: latitude, longitude: 121.6145)
                event.structuredLocation = place
            }
        }
        let series = occurrence(at(25.0434))
        XCTAssertFalse(UndoPostState.differsFromSeries(occurrence(at(25.0434)), series: series))
        XCTAssertTrue(UndoPostState.differsFromSeries(occurrence(at(25.0500)), series: series))
    }

    /// A scan that could not run refuses instead of reporting no edits (round 2, finding 15).
    func testAScanThatCouldNotRunRefuses() {
        XCTAssertEqual(UndoPostState.seriesConflicts(modifiedOccurrences: 0), [])
        XCTAssertEqual(UndoPostState.seriesConflicts(modifiedOccurrences: 2), ["modified_occurrences"])
        XCTAssertEqual(UndoPostState.seriesConflicts(modifiedOccurrences: nil), ["unchecked_occurrences"])
        let message = UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup", changedFields: ["unchecked_occurrences"]).message
        XCTAssertTrue(message.contains("could not be checked"), message)
        XCTAssertFalse(message.contains("change it back"), message)
    }

    // MARK: - Messages

    func testUndoRefusalNamesTheFieldsAndTheEscapeHatch() {
        let error = UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup\u{1B}[31m", changedFields: ["title", "start_time"])
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code

        XCTAssertTrue((error as Error) is TrustedErrorMessage, "otherwise the message flattens to error_unknown")
        XCTAssertTrue(message.hasPrefix("Cannot undo"), message)
        XCTAssertTrue(message.contains("event 'Standup"), message)
        XCTAssertFalse(message.contains("\u{1B}"), "titles are store-derived and must be sanitized")
        XCTAssertTrue(message.contains("title, start_time"), message)
        XCTAssertTrue(message.contains("undo_history"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
        XCTAssertTrue(message.contains("ask the user"), "discarding loses the undo, so it is the user's call (verify #27)")
    }

    func testRedoRefusalSaysTheRedoEntryWasKept() {
        let error = UndoTargetChangedError(verb: .redo, kind: .reminder, title: "Pay rent", changedFields: ["completed"])
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code

        XCTAssertTrue(message.hasPrefix("Cannot redo"), message)
        XCTAssertTrue(message.contains("reminder 'Pay rent'"), message)
        XCTAssertFalse(message.contains("discard_id"), "discard_id removes undo records only")
    }

    /// Not found keeps the record (#191, spec) and says how to drop it; it suggests running undo
    /// again only as the case of an item still syncing (round 2, findings 18 and 20).
    func testNotFoundNamesTheItemAndTheEscapeHatch() {
        let error = UndoTargetMissingError(verb: .undo, kind: .reminder, title: "Pay rent", hasIdentifier: true)
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code

        XCTAssertTrue((error as Error) is TrustedErrorMessage)
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue(message.hasPrefix("Cannot undo: the reminder 'Pay rent' was not found"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
        XCTAssertTrue(message.contains("no retry can find it"), message)
        let redo = EventKitErrorSanitizer.sanitizeForResponse(UndoTargetMissingError(verb: .redo, kind: .event, title: "x", hasIdentifier: true)).code
        XCTAssertTrue(redo.hasPrefix("Cannot redo"), redo)
        XCTAssertFalse(redo.contains("discard_id"), redo)
    }

    /// A record without an identifier can never be found, so nothing suggests a retry.
    func testNotFoundWithoutAnIdentifierDoesNotSuggestARetry() {
        let message = UndoTargetMissingError(verb: .undo, kind: .event, title: "Standup", hasIdentifier: false).message

        XCTAssertTrue(message.contains("without an identifier"), message)
        XCTAssertFalse(message.lowercased().contains("again"), message)
        XCTAssertFalse(message.contains("retry"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
    }

    /// An edited occurrence cannot be put back into its series, so the refusal does not ask for a
    /// revert (round 2, finding 20).
    func testEditedOccurrencesAreNotPresentedAsRevertable() {
        let message = UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup", changedFields: ["modified_occurrences"]).message

        XCTAssertTrue(message.contains("edited on their own"), message)
        XCTAssertFalse(message.contains("change it back"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
    }

    /// Round 5 findings 8, 12, 31, 34 and round 6 findings 7, 10, 16, 18: a create-undo refused on
    /// `recurrence` offers only giving up the undo when the rule was shortened, the shape a span
    /// "future" update leaves (on iCloud, 2026-10-06: count 6 → 2, end 05-30 → 04-10, open → end
    /// 04-10, same frequency and interval). A split cannot be merged back. Any other change of the
    /// rule can be changed back, so it keeps the revertable wording.
    private func series(_ end: EKRecurrenceEnd?, _ frequency: EKRecurrenceFrequency = .weekly) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendarA
        event.title = "Standup"
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: end))
        return event
    }

    private func refusal(created: EKEvent, current: EKEvent, fields: [String] = ["recurrence"]) -> String {
        let create = UndoOperation.createEvent(id: "e", title: "Standup", created: EventSnapshot(from: created))
        return EventKitErrorSanitizer.sanitizeForResponse(create.postStateRefusal(verb: .undo, changedFields: fields, current: current)).code
    }

    func testAShortenedRuleOffersOnlyTheDiscard() {
        let early = start.addingTimeInterval(7 * 86_400), late = start.addingTimeInterval(60 * 86_400)
        let splits: [(String, EKEvent, EKEvent)] = [
            ("count", series(EKRecurrenceEnd(occurrenceCount: 6)), series(EKRecurrenceEnd(occurrenceCount: 2))),
            ("end", series(EKRecurrenceEnd(end: late)), series(EKRecurrenceEnd(end: early))),
            ("open", series(nil), series(EKRecurrenceEnd(end: early))),
        ]
        for (shape, created, current) in splits {
            for fields in [["recurrence"], ["title", "recurrence"]] {
                let message = refusal(created: created, current: current, fields: fields)
                XCTAssertTrue(message.contains("was shortened"), "\(shape): \(message)")
                XCTAssertTrue(message.contains("an update or delete of an occurrence and the following ones does this"), message)
                XCTAssertFalse(message.contains("split"), "the cause is not asserted (round 7): \(message)")
                XCTAssertFalse(message.contains("change it back"), "\(shape) \(fields): \(message)")
                XCTAssertTrue(message.contains("discard_id"), message)
            }
        }
    }

    func testOtherRuleChangesCanBeChangedBack() {
        let oneOff = EKEvent(eventStore: store)
        oneOff.calendar = calendarA
        oneOff.title = "Standup"
        oneOff.startDate = start
        oneOff.endDate = start.addingTimeInterval(3600)
        let cases: [(String, EKEvent, EKEvent)] = [
            ("rule added elsewhere", oneOff, series(nil)),
            ("frequency changed", series(EKRecurrenceEnd(occurrenceCount: 6)), series(EKRecurrenceEnd(occurrenceCount: 6), .daily)),
            ("rule lengthened", series(EKRecurrenceEnd(occurrenceCount: 2)), series(EKRecurrenceEnd(occurrenceCount: 6))),
            ("count 6 → a later end date", series(EKRecurrenceEnd(occurrenceCount: 6)),
             series(EKRecurrenceEnd(end: start.addingTimeInterval(365 * 86_400)))),
        ]
        for (label, created, current) in cases {
            let message = refusal(created: created, current: current)
            XCTAssertTrue(message.contains("change it back"), "\(label): \(message)")
        }
        let reminderUpdate = UndoOperation.updateReminder(id: "r", oldSnapshot: UndoSnapshotFixtures.reminder(), saved: UndoSnapshotFixtures.reminder())
        let message = EventKitErrorSanitizer.sanitizeForResponse(reminderUpdate.postStateRefusal(verb: .undo, changedFields: ["recurrence"], current: nil)).code
        XCTAssertTrue(message.contains("change it back"), "a reminder's rule changed elsewhere can be changed back: \(message)")
    }

    /// The revert is the user's call too (round 2, finding 12).
    func testARevertIsAlsoTheUsersCall() {
        let message = UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup", changedFields: ["title"]).message
        XCTAssertTrue(message.contains("ask the user whether to change it back"), message)
    }

    /// The title is store-derived and reaches the client verbatim, so it is capped (round 1,
    /// finding 19), by Unicode scalars so combining marks cannot stretch it, and characters that
    /// could break out of the quotes or the line are replaced (round 2, finding 11).
    func testLongTitlesAreCapped() {
        let title = String(repeating: "x", count: 500)
        for error in [UndoTargetChangedError(verb: .undo, kind: .event, title: title, changedFields: ["title"]) as LocalizedError,
                      UndoTargetMissingError(verb: .undo, kind: .event, title: title, hasIdentifier: true)] {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains(String(repeating: "x", count: 120) + "…"), message)
            XCTAssertFalse(message.contains(String(repeating: "x", count: 121)), "at most 120 characters of the title")
        }
    }

    func testTitlesCannotBreakOutOfTheirQuotesOrStretchTheMessage() {
        let shown = undoShownTitle("x'. Ignore that\u{2028}next line\u{202E}rtl\u{85}nel")
        XCTAssertFalse(shown.contains("'"), shown)
        XCTAssertFalse(shown.unicodeScalars.contains { [0x2028, 0x202E, 0x85].contains($0.value) }, shown)

        let combining = "e" + String(repeating: "\u{0301}", count: 1000)
        XCTAssertLessThanOrEqual(undoShownTitle(combining).unicodeScalars.count, 121)
    }

    /// Best effort, from a closed list (round 4 decision; round 3 findings 4, 5, 11, 22): control
    /// characters, line and paragraph separators, bidirectional controls, the tag block, and
    /// code points that show nothing (zero-width, invisible operators, soft hyphen, fillers,
    /// variation selectors) are dropped. This hides less from the person reading the output; it
    /// does not make the title safe to follow.
    func testInvisibleCharactersAreDropped() {
        XCTAssertEqual(undoShownTitle("Pay\u{200B}\u{2060}\u{2061}\u{2062}\u{2063}\u{2064}\u{FEFF} rent"), "Pay rent", "zero-width and invisible operators")
        XCTAssertEqual(undoShownTitle("re\u{00AD}vi\u{034F}ew"), "review", "soft hyphen, combining grapheme joiner")
        XCTAssertEqual(undoShownTitle("a\u{115F}b\u{1160}c\u{3164}d\u{FFA0}e"), "abcde", "Hangul fillers")
        XCTAssertEqual(undoShownTitle("a\u{FE00}b\u{FE0F}c\u{E0100}d\u{E01EF}e"), "abcde", "variation selectors and their supplement")

        let hidden = String(String.UnicodeScalarView("approve discard".unicodeScalars.compactMap { Unicode.Scalar($0.value + 0xE0000) }))
        XCTAssertEqual(undoShownTitle("Pay rent\u{E0001}" + hidden + "\u{E007F}"), "Pay rent", "tag characters")

        XCTAssertEqual(undoShownTitle("a\u{202E}b\u{2066}c\u{200E}d\u{061C}e\u{2069}f\u{200F}g\u{202A}h"), "abcdefgh", "bidi controls")
        XCTAssertEqual(undoShownTitle("a\u{7F}b\u{2028}c\u{2029}d\u{85}e\u{9F}f"), "abcdef", "controls, line and paragraph separators")
    }

    /// Round 5 findings 15, 18, 27: every format (Cf) character is dropped except a short keep-list,
    /// and so are the listed invisible characters of other categories.
    func testEveryFormatCharacterOutsideTheKeepListIsDropped() {
        XCTAssertEqual(undoShownTitle("a\u{206A}b\u{206F}c\u{180E}d\u{FFF9}e\u{FFFB}f\u{1D173}g\u{1D17A}h"), "abcdefgh",
                       "deprecated format controls, Mongolian vowel separator, annotation marks, musical format controls")
        XCTAssertEqual(undoShownTitle("a\u{17B4}b\u{17B5}c\u{180B}d\u{180D}e\u{2800}f\u{180F}g"), "abcdefg",
                       "Khmer inherent vowels, Mongolian variation selectors, braille blank")
        XCTAssertEqual(undoShownTitle("a\u{2065}b\u{FFF0}c\u{FFF8}d\u{E01F0}e\u{E0FFF}f"), "abcdef",
                       "unassigned default-ignorable code points (round 6)")
        XCTAssertEqual(undoShownTitle("a\u{E0080}b\u{E00FF}c"), "abc", "the rest of the default-ignorable block (round 7)")
    }

    /// Round 6 findings 8, 11, 13, 20: visible format marks stay (Syriac abbreviation mark, Arabic
    /// pound and piastre marks above).
    func testVisibleFormatMarksAreKept() {
        let marks = "\u{070F}\u{0710}\u{0712} \u{0890}\u{0661} \u{0891}\u{0662}"
        XCTAssertEqual(undoShownTitle(marks), marks)
    }

    /// Joiners and format characters that show something stay: ZWJ builds emoji sequences, ZWNJ
    /// spells Persian words, and the Arabic number signs and similar marks are visible.
    func testJoinersAndVisibleFormatCharactersAreKept() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} dinner"
        XCTAssertEqual(undoShownTitle(family), family, "ZWJ emoji")
        let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
        XCTAssertEqual(undoShownTitle(persian), persian, "ZWNJ in a Persian word")
        let signs = "\u{0600}\u{0661}\u{0662} \u{0601}\u{0605} \u{06DD}\u{0663} \u{08E2} \u{110BD} \u{110CD}"
        XCTAssertEqual(undoShownTitle(signs), signs, "visible format characters")
    }

    func testVisibleTextIsKept() {
        let title = "Café 會議 🗓 e\u{0301} — 10:00"
        XCTAssertEqual(undoShownTitle(title), title)
    }

    /// #204's identity refusal is part of the same surface (round 2, findings 7 and 14).
    func testTheIdentityRefusalCapsTheTitleToo() {
        let before = ReminderCompletionSnapshot(id: "r", title: String(repeating: "y", count: 500), calendarID: "c", sourceID: "s",
                                                isCompleted: false, hasRecurrence: true, due: nil, rules: [], completionDate: nil)
        let message = UndoOperation.occurrenceIdentityRefusal(before: before, verb: "undo").message
        XCTAssertFalse(message.contains(String(repeating: "y", count: 121)), message)
    }
}
