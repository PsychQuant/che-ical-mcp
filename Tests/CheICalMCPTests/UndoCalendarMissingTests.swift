import CheMCPKit
import EventKit
import XCTest
@testable import CheICalMCP

/// #269: an event undo whose calendar is missing failed with `Calendar not found: <identifier>`,
/// which named neither the calendar nor the way on, while the kept record blocked every older one.
/// The refusal now has the shape of the reminder one (#242, `undoListMissing`): the calendar, its
/// account and the event named through `undoShownTitle`, nothing written, the entry kept, a retry
/// only while the account may be off, what giving up loses, then the ask-the-user → discard_id way
/// on worded as `UndoTargetChangedError`'s (#377: the discard comes first; no delete tool named).
final class UndoCalendarMissingTests: XCTestCase {
    /// The snapshot reads the calendar from the event, so the store lives as long as the test.
    private let store = EKEventStore()

    private func snapshot(calendarTitle: String = "Work", eventTitle: String = "Standup") -> EventSnapshot {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle
        let event = EKEvent(eventStore: store)
        event.title = eventTitle
        event.startDate = Date(timeIntervalSince1970: 1_900_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_900_003_600)
        event.calendar = calendar
        return EventSnapshot(from: event, includeRecurrence: false)
    }

    private func message(calendar: String = "Work", account: String? = "iCloud", event: String = "Standup",
                         hasIdentifier: Bool = true, kind: EventRestoreKind) throws -> String {
        try XCTUnwrap(EventKitError.undoCalendarMissing(calendar: calendar, account: account, event: event,
                                                        hasIdentifier: hasIdentifier, kind: kind).errorDescription)
    }

    /// The fields of a thrown `undoCalendarMissing`, or a failure for any other outcome.
    private func refusal(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line)
        -> (calendar: String, account: String?, event: String, hasIdentifier: Bool, kind: EventRestoreKind)? {
        do {
            _ = try body()
            XCTFail("expected the missing calendar to be refused", file: file, line: line)
        } catch EventKitError.undoCalendarMissing(let calendar, let account, let event, let hasIdentifier, let kind) {
            return (calendar, account, event, hasIdentifier, kind)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: - The message

    /// Names the calendar, account and event as `undoShownTitle` shows them: a subscribed or shared
    /// calendar's title is set by someone else (#37 F1), so a quote cannot close its quotes and
    /// hidden characters are dropped.
    func testTheRefusalNamesTheCalendarAccountAndEvent() throws {
        let text = try message(calendar: "Wo'rk\u{7}", account: "i\u{202E}Cloud", event: "Stand'up", kind: .recreateDeleted)
        XCTAssertTrue(text.contains("calendar 'Wo\u{2019}rk'"), text)
        XCTAssertTrue(text.contains("account 'iCloud'"), text)
        XCTAssertTrue(text.contains("event 'Stand\u{2019}up'"), text)
        XCTAssertFalse(text.contains("\u{7}"))
        XCTAssertFalse(text.contains("\u{202E}"))
    }

    /// A name that shows as nothing is left out instead of printed as `''`.
    func testANameThatShowsAsNothingIsLeftOut() throws {
        let text = try message(calendar: "Work", account: nil, event: "\u{200B}", kind: .revertUpdate)
        XCTAssertTrue(text.contains("(calendar 'Work')"), text)
        XCTAssertFalse(text.contains("account '"), text)
        XCTAssertFalse(text.contains("event ''"), text)
        let none = try message(calendar: "", account: nil, event: "", kind: .revertUpdate)
        XCTAssertTrue(none.contains("the calendar it was in before the update was not found"), none)
    }

    /// Nothing written, entry kept, no other calendar of that name used; then the way on, discard
    /// first, in `UndoTargetChangedError`'s words, with no delete tool named (#377).
    func testTheRefusalSaysNothingWasWrittenAndGivesTheWayOn() throws {
        for kind in [EventRestoreKind.recreateDeleted, .recreateDeletedOccurrence, .revertUpdate, .moveBack] {
            let text = try message(kind: kind)
            XCTAssertTrue(text.hasPrefix("Cannot undo the "), text)
            XCTAssertTrue(text.contains("Undo does not use another calendar of the same name."), text)
            XCTAssertTrue(text.contains("Nothing was written for this event and this history entry was kept"), text)
            XCTAssertTrue(text.hasSuffix("To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."), text)
            let written = try XCTUnwrap(text.range(of: "Nothing was written"))
            let discard = try XCTUnwrap(text.range(of: "discard_id"))
            XCTAssertLessThan(written.lowerBound, discard.lowerBound)
            for tool in ["delete_event", "delete_events_batch", "move_events_batch", "update_event", "create_event"] {
                XCTAssertFalse(text.contains(tool), "\(kind): names \(tool): \(text)")
            }
            XCTAssertFalse(text.contains("Calendar not found"), text)
        }
    }

    /// What is being undone, which calendar that is, and what giving up loses, per record.
    func testEachKindSaysWhichCalendarAndWhatGivingUpLoses() throws {
        let delete = try message(kind: .recreateDeleted)
        XCTAssertTrue(delete.hasPrefix("Cannot undo the deletion of an event: the calendar it was in when it was deleted (calendar 'Work', account 'iCloud', event 'Standup') was not found under its recorded identifier."), delete)
        XCTAssertTrue(delete.contains("Giving up this undo cannot be reversed, and this tool cannot recover the deleted event afterwards."), delete)

        let occurrence = try message(kind: .recreateDeletedOccurrence)
        XCTAssertTrue(occurrence.hasPrefix("Cannot undo the deletion of an occurrence of an event: the calendar it was in when it was deleted ("), occurrence)
        XCTAssertTrue(occurrence.contains("this tool cannot recover the deleted occurrence afterwards."), occurrence)

        let update = try message(kind: .revertUpdate)
        XCTAssertTrue(update.hasPrefix("Cannot undo the update of an event: the calendar it was in before the update ("), update)
        XCTAssertTrue(update.contains("Giving up this undo cannot be reversed; the event stays as it is now."), update)
        XCTAssertFalse(update.contains("deleted event"), update)

        let move = try message(kind: .moveBack)
        XCTAssertTrue(move.hasPrefix("Cannot undo the move of an event: the calendar it was moved from ("), move)
        XCTAssertTrue(move.contains("Giving up this undo cannot be reversed; the event stays in the calendar it was moved to."), move)
    }

    /// A retry is offered only while the calendar may come back (an account turned off or still
    /// syncing); a calendar recorded without an identifier can never be found, only given up.
    func testARetryIsOfferedOnlyWithAnIdentifier() throws {
        let withID = try message(kind: .moveBack)
        XCTAssertTrue(withID.contains("older undo entries stay blocked until it is undone or given up."), withID)
        XCTAssertTrue(withID.contains("Run undo again if the calendar's account may be turned off or still syncing; if the calendar was deleted, no retry can find it."), withID)

        let without = try message(hasIdentifier: false, kind: .moveBack)
        XCTAssertTrue(without.contains("was recorded without an identifier, so it cannot be found."), without)
        XCTAssertTrue(without.contains("until it is given up."), without)
        XCTAssertFalse(without.contains("Run undo again"), without)
    }

    /// Kept, as every not-found is (`undo-history-discard`); a trusted message, like #242's.
    func testTheRecordIsKept() {
        let error = EventKitError.undoCalendarMissing(calendar: "Work", account: nil, event: "Standup",
                                                      hasIdentifier: true, kind: .recreateDeleted)
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue((error as Any) is TrustedErrorMessage)
    }

    // MARK: - What reaches the refusal

    /// `EventSnapshot.resolveCalendar` (delete, occurrence and update undo, #208): a missing
    /// calendar is refused with the snapshot's calendar title, account and event title, and the
    /// kind the arm passed; a same-titled calendar is never used.
    func testTheSnapshotLookupRefusesWithItsRecordedNames() throws {
        let saved = snapshot(calendarTitle: "Work", eventTitle: "Standup")
        for kind in [EventRestoreKind.recreateDeleted, .recreateDeletedOccurrence, .revertUpdate] {
            let found = try XCTUnwrap(refusal {
                try saved.resolveCalendar(in: [(id: "other", title: "Work")], identifier: { $0.id }, for: kind)
            })
            XCTAssertEqual(found.calendar, "Work")
            XCTAssertEqual(found.account, saved.calendarSource)
            XCTAssertEqual(found.event, "Standup")
            XCTAssertTrue(found.hasIdentifier)
            XCTAssertEqual(found.kind, kind)
        }
        let present = try saved.resolveCalendar(in: [(id: "other", title: "Work"), (id: saved.calendarIdentifier, title: "Renamed")],
                                                identifier: { $0.id }, for: .revertUpdate)
        XCTAssertEqual(present.title, "Renamed")
    }

    /// The move record carries the calendar it was moved from, so its refusal can name it.
    func testTheMoveRecordsRefusalNamesTheCalendarItWasMovedFrom() throws {
        let move = UndoOperation.moveEvent(id: "E", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B",
                                           title: "Standup", isSeries: true,
                                           fromCalendarTitle: "Work", fromCalendarAccount: "iCloud")
        let found = try XCTUnwrap(refusal { throw try XCTUnwrap(move.moveBackCalendarMissing) })
        XCTAssertEqual(found.calendar, "Work")
        XCTAssertEqual(found.account, "iCloud")
        XCTAssertEqual(found.event, "Standup")
        XCTAssertTrue(found.hasIdentifier)
        XCTAssertEqual(found.kind, .moveBack)

        let unidentified = UndoOperation.moveEvent(id: "E", fromCalendarIdentifier: "", toCalendarIdentifier: "cal-B",
                                                   title: "Standup", isSeries: false,
                                                   fromCalendarTitle: "Work", fromCalendarAccount: nil)
        XCTAssertEqual(try XCTUnwrap(refusal { throw try XCTUnwrap(unidentified.moveBackCalendarMissing) }).hasIdentifier, false)
        XCTAssertNil(UndoOperation.createEvent(id: "E", title: "Standup", created: snapshot()).moveBackCalendarMissing,
                     "only a move record has a calendar it was moved from")
    }

    /// The whole-series move through the stand-in (#369, the second throw site): a stand-in still in
    /// the destination whose original calendar does not resolve is refused with the error the caller
    /// passes, which `seriesMoveUndoTarget` takes from the record (pinned below).
    func testTheStandInDecisionThrowsTheRecordsRefusal() throws {
        let move = UndoOperation.moveEvent(id: "S", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B",
                                           title: "Standup", isSeries: true,
                                           fromCalendarTitle: "Work", fromCalendarAccount: "iCloud")
        let expected = try XCTUnwrap(move.undoPostState)
        let found = try XCTUnwrap(refusal {
            try SeriesMoveUndo.decide(expected, verb: .undo, stored: { true },
                                      resolved: .init(event: "occurrence", viaStandIn: true, calendarID: "cal-B", sourceID: "icloud"),
                                      original: nil, missingOriginal: { move.moveBackCalendarMissing }) as Any
        })
        XCTAssertEqual(found.calendar, "Work")
        XCTAssertEqual(found.kind, .moveBack)
    }

    // MARK: - Wiring (EventKit paths an in-memory store cannot run)

    private func body(_ declaration: String, in file: String = "EventKit/EventKitManager.swift") throws -> String {
        let source = try SourcePins.source(file)
        return SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: source), declaration))
    }

    /// The arm between `case <record>` and the next `case`, whitespace collapsed.
    private func arm(_ label: String, of function: String) -> String? {
        guard let start = function.range(of: "case .\(label)(") else { return nil }
        let rest = function[start.upperBound...]
        let end = rest.range(of: " case .")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Each undo arm passes its own kind; the move arm throws the refusal built from its record.
    func testEachUndoArmPassesItsKind() throws {
        let undo = try body("func executeUndo(_ operation: UndoOperation)")
        let delete = try XCTUnwrap(arm("deleteEvent", of: undo))
        XCTAssertTrue(delete.contains("try applySnapshot(snapshot, to: event, for: .recreateDeleted)"), delete)
        let occurrence = try XCTUnwrap(arm("deleteOccurrence", of: undo))
        XCTAssertTrue(occurrence.contains("if try seriesHoldsSlot(of: snapshot, for: .recreateDeletedOccurrence) {"), occurrence)
        XCTAssertTrue(occurrence.contains("try applySnapshot(snapshot, to: event, for: .recreateDeletedOccurrence)"), occurrence)
        let update = try XCTUnwrap(arm("updateEvent", of: undo))
        XCTAssertTrue(update.contains("try applySnapshot(oldSnapshot, to: event, for: .revertUpdate)"), update)
        let move = try XCTUnwrap(arm("moveEvent", of: undo))
        XCTAssertTrue(move.contains("guard let original = eventStore.calendar(withIdentifier: fromCalendarIdentifier) else { throw EventKitError.moveBackCalendarMissing(fromCalendarIdentifier: fromCalendarIdentifier, fromCalendarTitle: fromCalendarTitle, fromCalendarAccount: fromCalendarAccount, event: title) }"), move)
        XCTAssertTrue(move.hasPrefix("_, let fromCalendarIdentifier, _, let title, let isSeries, let fromCalendarTitle, let fromCalendarAccount):"), move)
        XCTAssertFalse(undo.contains("calendarNotFound"), "no event undo arm throws the bare lookup error")
    }

    /// The lookups take the kind through to `resolveCalendar`.
    func testTheLookupsPassTheKindThrough() throws {
        let apply = try body("private func applySnapshot(_ snapshot: EventSnapshot")
        XCTAssertTrue(apply.contains("let originalCalendar = try snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier }, for: kind)"), apply)
        let slot = try body("func seriesHoldsSlot(of snapshot: EventSnapshot", in: "EventKit/EventKitManager+SeriesExceptions.swift")
        XCTAssertTrue(slot.contains("let calendar = try snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier }, for: kind)"), slot)
    }

    /// The stand-in path takes its refusal from the record it is undoing.
    func testTheStandInPathTakesTheRecordsRefusal() throws {
        let target = try body("private func seriesMoveUndoTarget(", in: "EventKit/EventKitManager+UndoGuard.swift")
        XCTAssertTrue(target.contains("missingOriginal: { operation.moveBackCalendarMissing })"), target)
        let guardBody = try body("func verifiedHistoryTarget(of operation: UndoOperation", in: "EventKit/EventKitManager+UndoGuard.swift")
        XCTAssertTrue(guardBody.contains("return try seriesMoveUndoTarget(operation, expected, verb: verb)"), guardBody)
        let decide = try body("static func decide<Event>(", in: "EventKit/SeriesMoveUndo.swift")
        XCTAssertTrue(decide.contains("guard let original else { throw missingOriginal() ?? EventKitError.calendarNotFound(identifier: restoring) }"), decide)
    }

    /// The in-place move records the calendar it moved the event out of: its identifier, title and
    /// account all from `originalCalendar`.
    func testTheMoveRecordsTheOriginalCalendarsNames() throws {
        // String literals are blanked in the pinned code, so the `title ?? ""` between the two
        // halves is not part of either.
        let move = try body("func moveEvent(")
        XCTAssertTrue(move.contains("undo = .moveEvent(id: movedIdentifier, fromCalendarIdentifier: originalCalendar.calendarIdentifier, toCalendarIdentifier: targetCalendar.calendarIdentifier,"), move)
        XCTAssertTrue(move.contains(", isSeries: isRecurring, fromCalendarTitle: originalCalendar.title, fromCalendarAccount: originalCalendar.source?.title)"), move)
    }
}
