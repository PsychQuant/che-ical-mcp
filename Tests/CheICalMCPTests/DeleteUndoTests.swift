import CheMCPKit
import EventKit
import XCTest
@testable import CheICalMCP

/// #244: a delete record used to be the series snapshot whatever the delete removed, so undo of a
/// single-occurrence delete recreated the whole series beside the original (on device: 3
/// occurrences, delete one, 2, undo, 5). The record now says what the delete removed.
final class DeleteUndoTests: XCTestCase {
    private let store = EKEventStore()
    private let firstStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func kind(hadRules: Bool, detached: Bool = false, span: EKSpan, seriesRemains: Bool) -> EventRemovalKind {
        EventRemovalKind.of(hadRules: hadRules, isDetached: detached, span: span, seriesRemains: seriesRemains)
    }

    /// A weekly series of three, as the issue's probe; an occurrence object carries the rules too.
    private func weekly(startingAt start: Date) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = "Standup"
        event.startDate = start
        event.endDate = start.addingTimeInterval(1800)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        return event
    }

    // MARK: - Classification

    func testAOneOffEventIsRemovedWhole() {
        for span in [EKSpan.thisEvent, .futureEvents] {
            XCTAssertEqual(kind(hadRules: false, span: span, seriesRemains: false), .wholeEvent)
        }
    }

    /// D1: span "this" removes one occurrence; undo brings it back as a one-off whatever is left of
    /// the series, so a second series can never come back.
    func testSpanThisOnASeriesRemovesOneOccurrence() {
        XCTAssertEqual(kind(hadRules: true, span: .thisEvent, seriesRemains: true), .occurrence)
        XCTAssertEqual(kind(hadRules: true, span: .thisEvent, seriesRemains: false), .occurrence)
    }

    /// Span "future" from the first occurrence leaves nothing: the series is recreated, as before.
    /// From a later one the series is still there, and the delete is refused at undo (D2).
    func testSpanFutureOnASeriesDependsOnWhetherTheSeriesRemains() {
        XCTAssertEqual(kind(hadRules: true, span: .futureEvents, seriesRemains: true), .followingOccurrences)
        XCTAssertEqual(kind(hadRules: true, span: .futureEvents, seriesRemains: false), .wholeEvent)
    }

    /// A detached occurrence addressed by its own identifier has no rules. Span "future" removes the
    /// following occurrences of its series too, which its snapshot does not hold: restoring the
    /// snapshot alone would leave them out silently, so it is refused, whether the series remains.
    func testADetachedOccurrenceIsAnOccurrenceAndWithSpanFutureIsRefused() {
        for remains in [true, false] {
            XCTAssertEqual(kind(hadRules: false, detached: true, span: .thisEvent, seriesRemains: remains), .occurrence)
            XCTAssertEqual(kind(hadRules: false, detached: true, span: .futureEvents, seriesRemains: remains), .followingOccurrences)
        }
    }

    // MARK: - Record shapes

    /// As the #208 move copy-out: the occurrence without its rules, at its own slot.
    func testAnOccurrenceDeleteRecordsTheOccurrenceWithoutRules() throws {
        let series = weekly(startingAt: firstStart)
        let second = weekly(startingAt: firstStart.addingTimeInterval(7 * 86_400))
        let record = DeletedEventSnapshots(series: series, removed: second).record(for: .occurrence)

        guard case .deleteOccurrence(let snapshot) = record else { return XCTFail("\(record)") }
        XCTAssertNil(snapshot.recurrenceRules, "no second series")
        XCTAssertEqual(snapshot.startDate, second.startDate)
        XCTAssertEqual(snapshot.endDate, second.endDate)
        XCTAssertEqual(snapshot.title, "Standup")
    }

    func testAWholeEventDeleteRecordsTheSeriesWithItsRules() throws {
        let series = weekly(startingAt: firstStart)
        let record = DeletedEventSnapshots(series: series, removed: series).record(for: .wholeEvent)

        guard case .deleteEvent(let snapshot) = record else { return XCTFail("\(record)") }
        XCTAssertEqual(snapshot.recurrenceRules?.count, 1)
        XCTAssertEqual(snapshot.startDate, firstStart)
    }

    func testAFollowingOccurrencesDeleteRecordsOnlyAMarker() {
        let series = weekly(startingAt: firstStart)
        let record = DeletedEventSnapshots(series: series, removed: weekly(startingAt: firstStart.addingTimeInterval(7 * 86_400)))
            .record(for: .followingOccurrences)

        guard case .deleteFollowingOccurrences(let title) = record else { return XCTFail("\(record)") }
        XCTAssertEqual(title, "Standup")
        XCTAssertNil(record.undoPostState, "nothing is compared, because nothing is written")
        XCTAssertNil(record.redoPostState)
    }

    func testTheNewRecordsHaveNoPostStateToCompare() {
        XCTAssertNil(UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Standup")).undoPostState,
                     "undo recreates; there is no item to overwrite")
    }

    // MARK: - undo_history

    func testHistoryDescriptionsSayWhatUndoWillDo() {
        let occurrence = UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Stand\u{202E}up 'x'"))
        XCTAssertEqual(occurrence.description, "Deleted occurrence of event: Standup 'x' (undo restores it as a one-off event)")
        let marker = UndoOperation.deleteFollowingOccurrences(title: "Stand\u{200B}up")
        XCTAssertEqual(marker.description, "Deleted occurrences of recurring event: Standup (undo not available)")
    }

    // MARK: - Refusals (D2, D3)

    func testUndoOfTheMarkerIsRefusedPermanently() {
        let error = UndoOperation.followingOccurrencesDeleteRefusal(title: "Standup\u{202E}")
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard, "D2: discarded so earlier operations stay undoable")
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.hasPrefix("Cannot undo the delete of the recurring event 'Standup'"), message)
        XCTAssertTrue(message.contains("the following occurrences"), message)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("earlier operations remain undoable"), message)
        XCTAssertTrue(message.contains("in Calendar"), message)
        XCTAssertFalse(message.contains("discard_id"), "the entry is already discarded")
    }

    /// D3: a batch that holds such a delete is refused before any member writes, and discarded.
    func testABatchMemberThatCannotBeRestoredRefusesTheWholeBatch() throws {
        let error = try XCTUnwrap(UndoOperation.deleteFollowingOccurrences(title: "Standup").batchMemberUndoRefusal)
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.hasPrefix("Cannot undo this batch"), message)
        XCTAssertTrue(message.contains("'Standup'"), message)
        XCTAssertTrue(message.contains("none of the batch's events were restored"), message)
        XCTAssertTrue(message.contains("earlier operations remain undoable"), message)
    }

    func testRestorableBatchMembersPassTheCheck() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup")
        XCTAssertNil(UndoOperation.deleteEvent(snapshot: snapshot).batchMemberUndoRefusal)
        XCTAssertNil(UndoOperation.deleteOccurrence(snapshot: snapshot).batchMemberUndoRefusal)
        XCTAssertNil(UndoOperation.createEvent(id: "e", title: "Standup", created: snapshot).batchMemberUndoRefusal)
    }
}
