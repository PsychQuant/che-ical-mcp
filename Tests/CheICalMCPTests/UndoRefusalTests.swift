import CheMCPKit
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
        let successor = reminder(completed: false)

        let fields = try XCTUnwrap(op.undoPostState).changedFields(in: successor)
        XCTAssertEqual(fields, ["completed"])
        let error = op.postStateRefusal(verb: .undo, changedFields: fields)
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "kept: the spec keeps refused records, and nothing proves the advance")
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.contains("later occurrence"), message)
        XCTAssertFalse(message.contains("change it back"), "there is no change to revert")
        XCTAssertTrue(message.contains("discard_id"), message)
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
        let error = op.postStateRefusal(verb: .undo, changedFields: ["completed"])
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
        XCTAssertEqual(UndoFailureDisposition.of(update.postStateRefusal(verb: .undo, changedFields: ["title"])), .restore)
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

    // MARK: - Which detached occurrences count (round 3, finding 7)

    private func face(start: Date? = nil, slot: Date?? = nil, title: String? = "Standup", notes: String? = nil,
                      location: String? = "Room 1", url: String? = nil, allDay: Bool = false,
                      duration: TimeInterval = 3600) -> UndoPostState.OccurrenceFace {
        let begins = start ?? self.start
        return UndoPostState.OccurrenceFace(start: begins, slot: slot ?? begins, title: title, notes: notes, location: location,
                                            url: url, isAllDay: allDay, duration: duration)
    }

    /// The tool's own sequence: an occurrence updated (detached) and that update undone. The
    /// occurrence stays detached, but it holds the series' values again, so it is not an edit and
    /// does not block the create-undo of the series.
    func testAnOccurrenceUndoneBackToTheSeriesIsNotAnEdit() {
        let series = face()
        let updated = face(title: "Standup (moved talk)", notes: "updated")
        let undone = face()

        XCTAssertTrue(UndoPostState.differsFromSeries(updated, series: series), "after the update")
        XCTAssertFalse(UndoPostState.differsFromSeries(undone, series: series), "after its undo")
        XCTAssertEqual(UndoPostState.seriesConflicts(modifiedOccurrences: [updated, undone].filter {
            UndoPostState.differsFromSeries($0, series: series)
        }.count), ["modified_occurrences"], "an occurrence that still differs still refuses")
    }

    /// Each field the rule names counts on its own; nothing else does.
    func testWhatMakesAnOccurrenceDiffer() {
        let series = face()
        let differs = { (occurrence: UndoPostState.OccurrenceFace) in UndoPostState.differsFromSeries(occurrence, series: series) }

        XCTAssertTrue(differs(face(start: start.addingTimeInterval(1800), slot: .some(start))), "moved off its slot")
        XCTAssertTrue(differs(face(title: "Retro")))
        XCTAssertTrue(differs(face(notes: "agenda")))
        XCTAssertTrue(differs(face(location: "Room 2")))
        XCTAssertTrue(differs(face(url: "https://example.com")))
        XCTAssertTrue(differs(face(allDay: true)))
        XCTAssertTrue(differs(face(duration: 5400)))
        XCTAssertTrue(differs(face(slot: .some(nil))), "no slot to compare with: counted, the side that refuses")

        XCTAssertFalse(differs(face(start: start.addingTimeInterval(7 * 86_400))), "on its own slot a week later")
        XCTAssertFalse(differs(face(notes: "")), "no notes and empty notes are the same")
        XCTAssertFalse(differs(face(start: start.addingTimeInterval(0.4), slot: .some(start))), "to the second")
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

    /// Characters a reader does not see are dropped by general category (format, control, line
    /// and paragraph separators, private use, unassigned) and the tag block, not by a hand-written
    /// list (round 3, findings 4, 5, 11, 22). This hides less from the person reading the output;
    /// it does not make the title safe to follow.
    func testInvisibleCharactersAreDroppedByCategory() {
        let zeroWidth = "Pay\u{200B}\u{200C}\u{200D}\u{2060}\u{2062}\u{FEFF} rent"
        XCTAssertEqual(undoShownTitle(zeroWidth), "Pay rent")
        XCTAssertEqual(undoShownTitle("re\u{00AD}view"), "review", "soft hyphen")

        let hidden = String(String.UnicodeScalarView("approve discard".unicodeScalars.compactMap { Unicode.Scalar($0.value + 0xE0000) }))
        XCTAssertEqual(undoShownTitle("Pay rent\u{E0001}" + hidden + "\u{E007F}"), "Pay rent", "tag characters")

        XCTAssertEqual(undoShownTitle("a\u{202E}b\u{2066}c\u{200E}d\u{061C}e\u{2069}f"), "abcdef", "bidi controls")
        XCTAssertEqual(undoShownTitle("a\u{E000}b\u{0378}c\u{2028}d\u{2029}e\u{85}f"), "abcdef",
                       "private use, unassigned, line and paragraph separators, C1")
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
