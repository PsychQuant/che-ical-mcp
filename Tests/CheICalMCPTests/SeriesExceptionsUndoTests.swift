import EventKit
import XCTest
@testable import CheICalMCP

/// #322: the delete-undo exceptions layer (`SeriesExceptionsUndo`, #285) run against an in-memory
/// store (`FakeSeriesExceptionsStore`): what the capture records, what the two undo arms write and
/// in which order, and what they answer when a write fails. Before #322 this code talked to
/// EventKit directly and was checked on device only.
final class SeriesExceptionsUndoTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var s1: Date { s0.addingTimeInterval(7 * day) }
    private var s2: Date { s0.addingTimeInterval(14 * day) }
    private var s3: Date { s0.addingTimeInterval(21 * day) }

    private func slotLog(_ date: Date) -> String { "remove \(date.timeIntervalSince1970)" }

    // MARK: - capture

    /// A series of four weekly occurrences: the third deleted on its own, the second edited on its
    /// own and moved by half an hour, and another series in the same calendar. The capture keeps
    /// the slots that exist unedited, records the edited one by its rule slot, ignores the other
    /// series, and lists the window and a year each side as three queries. The edited occurrence
    /// reads back as iCloud showed (#311): its identifiers carry `/RID=<seconds since 2001>` of its
    /// slot, and its `occurrenceDate` has drifted to the moved start, so only the `/RID=` reading
    /// of `SeriesExceptionsPlanner.ruleSlot` gives the slot.
    func testTheCaptureRecordsKeptSlotsAndEditedOccurrencesOfThisSeriesOnly() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: [s0, s1, s3])
        let rid = "/RID=\(Int(s1.timeIntervalSinceReferenceDate))"
        occurrences[1].id = "S" + rid
        occurrences[1].external = "X-S" + rid
        occurrences[1].detached = true
        occurrences[1].start = s1.addingTimeInterval(1800)
        occurrences[1].occurrenceDate = occurrences[1].start
        store.addSeries(id: "T", calendar: "C", title: "Other", slots: [s0, s2])
        store.window = DateInterval(start: s0.addingTimeInterval(-day), end: s3.addingTimeInterval(day))

        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store))

        XCTAssertEqual(exceptions.keptSlots, [s0, s3])
        XCTAssertEqual(exceptions.detached.map(\.slot), [s1])
        XCTAssertEqual(exceptions.window, store.window)
        XCTAssertEqual(store.log, ["list", "list", "list"], "the window and a year on each side, one query each")
    }

    /// Nothing is listed for a series without a calendar or without an identifier: the record then
    /// says its exceptions were not checked (nil), not that it had none.
    func testTheCaptureIsNilWithoutACalendarOrAnIdentifier() {
        let store = FakeSeriesExceptionsStore()
        let noCalendar = FakeSeriesExceptionsStore.Event(id: "S", title: "Standup", start: s0, hasRules: true)
        XCTAssertNil(SeriesExceptionsUndo.capture(of: noCalendar, in: store))
        let noID = FakeSeriesExceptionsStore.Event(id: "", calendar: "C", title: "Standup", start: s0, hasRules: true)
        XCTAssertNil(SeriesExceptionsUndo.capture(of: noID, in: store))
        XCTAssertEqual(store.log, [], "nothing listed")
    }

    // MARK: - undo of a whole-series delete

    /// The series recorded with s0 and s1 kept, s2 edited on its own (moved), s3 deleted on its own:
    /// undo saves the series from its rules, lists its occurrences over the recorded window, removes
    /// s2 and s3, then recreates the edited one as a one-off. The text counts one of each.
    private func recordedSeries() -> (snapshot: EventSnapshot, edited: EventSnapshot) {
        let edited = UndoSnapshotFixtures.event(title: "Standup moved", startDate: s2.addingTimeInterval(1800))
        let exceptions = SeriesExceptions(window: DateInterval(start: s0.addingTimeInterval(-day), end: s3.addingTimeInterval(day)),
                                          keptSlots: [s0, s1], detached: [DetachedOccurrence(slot: s2, snapshot: edited)])
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0).withExceptions(exceptions)
        return (series, edited)
    }

    func testTheWholeSeriesUndoRestoresTheRecordedExceptions() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let (series, edited) = recordedSeries()

        let text = try SeriesExceptionsUndo.undoDeleteEvent(series, in: store)

        XCTAssertEqual(store.log, ["save series Standup", "list", slotLog(s2), slotLog(s3), "save Standup moved"])
        XCTAssertEqual(store.starts(of: "E1"), [s0, s1], "the series keeps the slots that existed unedited")
        XCTAssertEqual(store.events.filter { $0.title == "Standup moved" }.map(\.start), [edited.startDate],
                       "the edited occurrence is back as a one-off at its edited start")
        XCTAssertTrue(text.hasPrefix("Undone: restored event 'Standup' (new ID: E1)"), text)
        XCTAssertTrue(text.contains("1 occurrence(s) deleted on their own earlier stayed deleted, 1 occurrence(s) edited on their own came back"), text)
        XCTAssertEqual(store.refreshMarks, 1)
    }

    /// No recorded exceptions (the capture was nil): the series comes back from its rules alone,
    /// nothing is listed or removed, and the text says so.
    func testAWholeSeriesUndoWithoutRecordedExceptionsRestoresFromTheRulesAlone() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0)

        let text = try SeriesExceptionsUndo.undoDeleteEvent(series, in: store)

        XCTAssertEqual(store.log, ["save series Standup"])
        XCTAssertEqual(store.starts(of: "E1"), [s0, s1, s2, s3])
        XCTAssertEqual(text, "Undone: restored event 'Standup' (new ID: E1). " + UndoOperation.seriesRulesRestoreNote)
    }

    /// The edited occurrence cannot be saved: the series is deleted again, nothing is left, and the
    /// error keeps the record (`.restore`, so the user can retry or give it up).
    func testAOneOffThatCannotBeSavedDeletesTheSeriesAgainAndKeepsTheRecord() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]

        XCTAssertThrowsError(try SeriesExceptionsUndo.undoDeleteEvent(recordedSeries().snapshot, in: store)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Undo could not recreate the occurrence edited on its own on "), error.localizedDescription)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        }
        XCTAssertEqual(store.log.suffix(2), ["save failed Standup moved", "remove series"])
        XCTAssertEqual(store.events.count, 0, "nothing of the recreated series or the one-off is left")
    }

    /// The compensating delete fails too: permanent, the record is discarded (a retry would create
    /// a second series).
    func testAFailedCompensatingDeleteIsPermanent() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]
        store.seriesRemovalFails = true

        XCTAssertThrowsError(try SeriesExceptionsUndo.undoDeleteEvent(recordedSeries().snapshot, in: store)) { error in
            XCTAssertTrue(error is UnrecoverableUndoError, "\(error)")
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
            XCTAssertTrue(error.localizedDescription.contains("the series exists with 2 occurrence(s) removed"), error.localizedDescription)
        }
    }

    // MARK: - undo of an occurrence delete

    /// The calendar already holds a recurring event with the occurrence's title at its start (the
    /// series came back from its rules): nothing is written.
    func testAnOccurrenceWhoseSlotTheSeriesHoldsIsNotWrittenAgain() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1)
        store.addSeries(id: "S", calendar: occurrence.calendarIdentifier, title: "Standup", slots: [s0, s1])

        let text = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: [], in: store)

        XCTAssertEqual(text, UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup"))
        XCTAssertEqual(store.log, ["holders"], "nothing saved")
    }

    /// The slot is free (only a one-off with that title is there): the occurrence comes back as a
    /// one-off event.
    func testAnOccurrenceWhoseSlotIsFreeComesBackAsAOneOff() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1)
        store.add(.init(id: "O", calendar: occurrence.calendarIdentifier, title: "Standup", start: s1))

        let text = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: ["absolute_alarms"], in: store)

        XCTAssertEqual(store.log, ["holders", "save Standup"])
        XCTAssertEqual(text, UndoOperation.occurrenceRestoredMessage(title: "Standup", newID: "E1", notCarriedOver: ["absolute_alarms"]))
        XCTAssertEqual(store.refreshMarks, 1)
    }
}
