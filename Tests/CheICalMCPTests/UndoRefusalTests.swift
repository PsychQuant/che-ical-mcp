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

    // MARK: - Legacy recurring completion (verify #4 / #18 / #20)

    /// A completion record of a recurring reminder kept without the #204 identity snapshot: when
    /// its completion no longer matches, the identifier most likely resolves to a later
    /// occurrence (EventKit advances a recurring reminder in place), which no revert can undo.
    /// The record is discarded with that reason, as #204 does for identifiable items.
    func testALegacyRecurringCompletionMismatchIsPermanentAndSaysWhy() {
        let legacy = UndoOperation.completeReminder(id: "r", wasCompleted: true, requestedCompleted: true,
                                                    completionDate: start, title: "Daily", redoCompletionDate: start)
        let error = legacy.postStateRefusal(verb: .undo, changedFields: ["completed"], itemIsRecurring: true)

        XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.contains("later occurrence"), message)
        XCTAssertFalse(message.contains("Revert the change"), "nobody changed anything that could be reverted")
    }

    func testOtherRefusalsKeepTheRecord() {
        let legacy = UndoOperation.completeReminder(id: "r", wasCompleted: true, requestedCompleted: true,
                                                    completionDate: start, title: "Once", redoCompletionDate: start)
        XCTAssertEqual(UndoFailureDisposition.of(legacy.postStateRefusal(verb: .undo, changedFields: ["completed"], itemIsRecurring: false)), .restore)
        let update = UndoOperation.updateReminder(id: "r", oldSnapshot: UndoSnapshotFixtures.reminder(), saved: UndoSnapshotFixtures.reminder())
        XCTAssertEqual(UndoFailureDisposition.of(update.postStateRefusal(verb: .undo, changedFields: ["title"], itemIsRecurring: true)), .restore)
    }

    // MARK: - Series create-undo (verify #1)

    /// The delete of a series removes every occurrence, so create-undo looks for occurrences
    /// edited elsewhere. EventKit matches at most four years per query; the scan covers the
    /// series from a day before its first occurrence to a day after its end, at most 1460 days.
    func testTheSeriesScanWindow() {
        let open = UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: nil)
        XCTAssertEqual(open.start, start.addingTimeInterval(-86_400))
        XCTAssertEqual(open.end, start.addingTimeInterval(1460 * 86_400))

        let ending = UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: start.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(ending.end, start.addingTimeInterval(31 * 86_400))
    }

    /// On device (iCloud, 2026-10-05) an occurrence edited on its own reads back with its own
    /// identifier, the series identifier plus `/RID=<seconds>`, and deleting the series removes
    /// it too. So the scan matches that form as well as the bare series identifier.
    func testAnEditedOccurrenceIsRecognisedByItsIdentifier() {
        let series = "29034CB8-B308-40D1-A11D-F727B1EA1F46:098D5E80-E343-45A3-B4B5-CFF9E930E9E0"
        XCTAssertTrue(UndoPostState.isOccurrence(identifier: series, ofSeries: series))
        XCTAssertTrue(UndoPostState.isOccurrence(identifier: series + "/RID=815878800", ofSeries: series))
        XCTAssertFalse(UndoPostState.isOccurrence(identifier: "29034CB8-B308-40D1-A11D-F727B1EA1F46:6384413B", ofSeries: series))
        XCTAssertFalse(UndoPostState.isOccurrence(identifier: series + "0", ofSeries: series))
        XCTAssertFalse(UndoPostState.isOccurrence(identifier: nil, ofSeries: series))
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

    /// verify #10 / #17: not found keeps the record (#191, spec) and now says how to drop it.
    func testNotFoundNamesTheItemAndTheEscapeHatch() {
        let error = UndoTargetMissingError(verb: .undo, kind: .reminder, title: "Pay rent")
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code

        XCTAssertTrue((error as Error) is TrustedErrorMessage)
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue(message.hasPrefix("Cannot undo: the reminder 'Pay rent' was not found"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
        let redo = EventKitErrorSanitizer.sanitizeForResponse(UndoTargetMissingError(verb: .redo, kind: .event, title: "x")).code
        XCTAssertTrue(redo.hasPrefix("Cannot redo"), redo)
        XCTAssertFalse(redo.contains("discard_id"), redo)
    }

    /// verify #19: the title is store-derived and reaches the client verbatim, so it is capped.
    func testLongTitlesAreCapped() {
        let title = String(repeating: "x", count: 500)
        for error in [UndoTargetChangedError(verb: .undo, kind: .event, title: title, changedFields: ["title"]) as LocalizedError,
                      UndoTargetMissingError(verb: .undo, kind: .event, title: title)] {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains(String(repeating: "x", count: 120) + "…"), message)
            XCTAssertFalse(message.contains(String(repeating: "x", count: 121)), "at most 120 characters of the title")
        }
    }
}
