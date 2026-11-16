import EventKit
import XCTest
@testable import CheICalMCP

/// #246: an `update_event` that moves the event to a calendar in another account changes its
/// identifier (#226, on device). The undo record has to carry the identifier the event has after
/// the save, or the undo looks the event up under the old one and fails as not found.
final class EventUpdateRecordTests: XCTestCase {
    private var store: EKEventStore { SharedTestStore.store }

    private func snapshot(title: String) -> EventSnapshot {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = title
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        return EventSnapshot(from: event)
    }

    func testAOneOffUpdateRecordsTheIdentifierTheEventHasAfterTheSave() throws {
        var postStateReads: [String] = []
        let op = EventUpdateRecord.operation(
            requestedID: "before-save", identifierAfterSave: "after-save", oldSnapshot: snapshot(title: "Before"),
            recurringKind: nil, seriesRecord: nil, postState: { postStateReads.append($0); return self.snapshot(title: "After") })

        guard case .updateEvent(let id, let old, let saved) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(id, "after-save")
        XCTAssertEqual(old.title, "Before")
        XCTAssertEqual(saved.title, "After")
        XCTAssertEqual(postStateReads, ["after-save"], "the post-state is read the way undo reads it")
        guard case .event(let lookupID, _, _, _)? = op.undoPostState else { return XCTFail("\(op)") }
        XCTAssertEqual(lookupID, "after-save", "undo looks the event up under this identifier")
    }

    func testARecurringUpdateMarkerCarriesTheIdentifierAfterTheSave() {
        var postStateReads: [String] = []
        let op = EventUpdateRecord.operation(
            requestedID: "before-save", identifierAfterSave: "after-save", oldSnapshot: snapshot(title: "Weekly"),
            recurringKind: .series, seriesRecord: nil, postState: { postStateReads.append($0); return self.snapshot(title: "x") })

        guard case .updateRecurringEvent(let id, let title, let kind) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(id, "after-save")
        XCTAssertEqual(title, "Weekly")
        XCTAssertEqual(kind, .series)
        XCTAssertEqual(postStateReads, [], "a marker restores nothing, so it reads no post-state")
    }

    /// #263: a whole-series update the record site found restorable is recorded with what its undo
    /// restores and compares; without that record it stays the marker above.
    func testAWholeSeriesUpdateWithASeriesRecordIsRestorable() {
        let exceptions = SeriesExceptions(window: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86_400),
                                          keptSlots: [], detached: [])
        let series = SeriesUpdateRecord(id: "S", externalIdentifier: "X-S", old: snapshot(title: "Weekly"), saved: snapshot(title: "x"),
                                        fields: ["title"], before: exceptions, after: exceptions)
        let op = EventUpdateRecord.operation(
            requestedID: "S", identifierAfterSave: "S", oldSnapshot: snapshot(title: "Weekly"),
            recurringKind: .series, seriesRecord: series, postState: { _ in self.snapshot(title: "x") })
        guard case .updateSeries(let recorded) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(recorded.fields, ["title"])

        for kind: RecurringUpdateKind in [.occurrence, .future, .rulesAdded, .rulesRemoved] {
            let other = EventUpdateRecord.operation(
                requestedID: "S", identifierAfterSave: "S", oldSnapshot: snapshot(title: "Weekly"),
                recurringKind: kind, seriesRecord: series, postState: { _ in self.snapshot(title: "x") })
            guard case .updateRecurringEvent(_, _, let marked) = other else { return XCTFail("\(kind): \(other)") }
            XCTAssertEqual(marked, kind, "only the whole-series kind takes the record")
        }
    }

    /// The event normally has an identifier after a save; if it has none, the requested one is
    /// the best the record can hold (the undo then fails as not found and keeps the record).
    func testTheRequestedIdentifierIsTheFallbackWhenTheSavedEventHasNone() {
        let op = EventUpdateRecord.operation(
            requestedID: "before-save", identifierAfterSave: nil, oldSnapshot: snapshot(title: "Before"),
            recurringKind: nil, seriesRecord: nil, postState: { _ in self.snapshot(title: "After") })

        guard case .updateEvent(let id, _, _) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(id, "before-save")
    }

    // MARK: - updateEvent records through the seam

    /// The tests above pin the seam; this pins its one caller. `updateEvent` has to hand the seam
    /// the identifier read off the event after the save. Passing the requested `identifier` there,
    /// recording before the save, or recording `.updateEvent` / `.updateRecurringEvent` directly
    /// brings #246 back. It reads the source text (comments removed, whitespace collapsed), so it
    /// is a guard against a revert, not a behaviour test, and it is sensitive to wording: renaming
    /// the local `event`, or `eventStore.save(event, span: span)`, turns it red with the behaviour
    /// unchanged; update the expected text then.
    func testUpdateEventRecordsThroughTheSeamWithTheIdentifierReadAfterTheSave() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(
            SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))

        XCTAssertEqual(code.components(separatedBy: "EventUpdateRecord.operation(").count - 1, 1,
                       "updateEvent builds its undo record with EventUpdateRecord.operation")
        let arguments = try XCTUnwrap(SourceScan.arguments(of: "EventUpdateRecord.operation(", in: code))
        XCTAssertTrue(arguments.contains("identifierAfterSave: event.eventIdentifier"), arguments)

        let body = try XCTUnwrap(code.range(of: "func updateEvent(")).upperBound
        let save = try XCTUnwrap(code.range(of: "try eventStore.save(event, span: span)", range: body..<code.endIndex))
        let record = try XCTUnwrap(code.range(of: "EventUpdateRecord.operation(", range: body..<code.endIndex))
        XCTAssertLessThan(save.lowerBound, record.lowerBound, "the record is built after the save")

        for direct in [#"record\s*\(\s*\.updateEvent\s*\("#, #"record\s*\(\s*\.updateRecurringEvent\s*\("#,
                       #"record\s*\(\s*\.updateSeries\s*\("#] {
            XCTAssertNil(code.range(of: direct, options: .regularExpression), "record through EventUpdateRecord, not \(direct)")
        }
    }

    // MARK: - #484: older records follow a calendar change made through update_event

    private func follow(_ requested: String, _ saved: String?, calendar: Bool = true, whole: Bool = true,
                        standIn: Bool = false, own: Bool = false) -> String? {
        EventUpdateRecord.identifierToFollow(requestedID: requested, identifierAfterSave: saved, changedCalendar: calendar,
                                             wholeEvent: whole, viaStandIn: standIn, ownOccurrenceID: own)
    }

    /// spec-example: undo-history-discard / the five conditions of the forward rewrite
    /// Measured on a Google account (#484, 2026-11-13): a one-off, and a whole series with span all.
    func testACalendarChangeOverTheWholeEventFollowsTheNewIdentifier() {
        XCTAssertEqual(follow("A", "B"), "B", "a one-off moved to another calendar")
        XCTAssertEqual(follow("S", "T"), "T", "the series object with span all")
    }

    /// Condition 1. A new identifier with no calendar change is a split or a remainder, not this event renamed.
    func testNoRewriteWithoutACalendarChange() {
        XCTAssertNil(follow("A", "B", calendar: false))
    }

    /// Condition 2. An occurrence picked by occurrence_date (span this or future): the old identifier
    /// still names the series it was picked from.
    func testNoRewriteWhenAnOccurrenceWasPicked() {
        XCTAssertNil(follow("S", "T", whole: false))
    }

    /// Condition 3 (#326).
    func testNoRewriteThroughTheStandIn() {
        XCTAssertNil(follow("S", "T", standIn: true))
    }

    /// Condition 4 (#416, #428). The identifiers differ in their series part, so only this condition stops it.
    func testNoRewriteThroughAnOccurrencesOwnIdentifier() {
        XCTAssertNil(follow("S/RID=1800000000", "T/RID=1800000000", own: true))
    }

    /// Condition 5: unchanged (iCloud within one account), nothing read back, or nothing at all.
    func testNoRewriteWhenTheIdentifierIsUnchangedOrMissing() {
        XCTAssertNil(follow("A", "A"))
        XCTAssertNil(follow("A", ""))
        XCTAssertNil(follow("A", nil))
    }

    /// Condition 5 compares the series part: `S` read back as an occurrence's own id of the same series.
    func testAnOccurrenceFormOfTheSameSeriesIsNotANewIdentifier() {
        XCTAssertNil(follow("S", "S/RID=1800000000"))
        XCTAssertNil(follow("S/RID=1800000000", "S"))
    }

    /// spec-example: undo-history-discard / the answer of an update's undo with and without a new identifier
    func testTheUpdateUndoAnswerGivesTheNewIdentifierOnlyWhenThereIsOne() {
        XCTAssertEqual(EventUpdateRecord.updateUndoneText(title: "Standup", newID: nil),
                       "Undone: restored event 'Standup' to previous state", "today's text, byte for byte")
        XCTAssertEqual(EventUpdateRecord.updateUndoneText(title: "Standup", newID: "NEW-1"),
                       "Undone: restored event 'Standup' to previous state (new ID: NEW-1)")
    }

    func testTheUpdateUndoAnswerShowsTheTitleAsEveryUndoneTextDoes() {
        let text = EventUpdateRecord.updateUndoneText(title: "Stand\u{1B}[31mup\u{200B}", newID: "NEW-1")
        XCTAssertFalse(text.contains("\u{1B}"), text)
        XCTAssertFalse(text.contains("\u{200B}"), text)
        XCTAssertTrue(text.hasSuffix(" (new ID: NEW-1)"), text)
    }
}
