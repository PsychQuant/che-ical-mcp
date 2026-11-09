import XCTest
@testable import CheICalMCP

/// #503: the deleted-occurrence refusal in `updateEvent` reads the store, so no unit test runs it.
/// It runs after #442's all_day refusal and before the first field of the event is assigned
/// (#373: a refusal after an assignment leaves the rejected values on the cached object), and it
/// reads the series' listing the way #442 does.
final class DeletedOccurrenceWiringTests: XCTestCase {
    func testTheRefusalRunsBeforeTheFirstAssignment() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        let allDay = try XCTUnwrap(update.range(of: "DetachedOccurrenceSpan.refusesAllDayChange("))
        let applies = try XCTUnwrap(update.range(of: "DeletedOccurrenceCheck.applies("))
        let verdict = try XCTUnwrap(update.range(of: "deletedOccurrenceVerdict("))
        let first = try XCTUnwrap(update.range(of: "if let t = title { event.title = t }"))
        XCTAssertLessThan(allDay.lowerBound, applies.lowerBound)
        XCTAssertLessThan(applies.lowerBound, verdict.lowerBound)
        XCTAssertLessThan(verdict.lowerBound, first.lowerBound)
        XCTAssertTrue(update.contains("reachesSeveral: reach.isWholeSeries || reach.isFromLaterOccurrence"))
        // PR #505 round 1: a whole-series write filters no slot, and a stand-in is passed as such.
        XCTAssertTrue(update.contains("reachedFrom: DeletedOccurrenceCheck.reachedFrom(isWholeSeries: reach.isWholeSeries, anchor: reach.anchor)"))
        XCTAssertTrue(update.contains("viaStandIn: addressesOwnOccurrence ? false : resolved.viaStandIn"))
        // PR #505 round 2: a zone change is checked (measured), and the route facts are passed.
        XCTAssertTrue(update.contains("resultAllDay: datePlan.isAllDay, storedAllDay: event.isAllDay, changesZone: changesZone"))
        XCTAssertTrue(update.contains("changesAllDay: datePlan.isAllDay != event.isAllDay"))
        XCTAssertTrue(update.contains("if addressesOwnOccurrence { _ = series?.refresh() }"))
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.deletedReason"))
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.unknownReason"))
        // PR #505 round 4 (MEDIUM): a calendar of another account goes through the same verdict.
        XCTAssertTrue(update.contains("if deletedOccurrenceCheckApplies(changesAccount: crossesAccounts) {"))
        XCTAssertTrue(update.contains("let onlyTheAccount = !deletedOccurrenceCheckApplies(changesAccount: false)"))
        XCTAssertTrue(update.contains("case _ where onlyTheAccount: throw EventKitError.seriesWriteRefused(reason: DeletedOccurrenceCheck.accountMoveReason(verdict))"))
    }

    /// PR #505 round 4 (MEDIUM): `move_events_batch` of a whole series to another account checks the
    /// series before anything is written.
    func testAMoveToAnotherAccountChecksTheSeriesFirst() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let move = try XCTUnwrap(SourcePins.body(of: "func moveEvent(", in: manager))
        let check = try XCTUnwrap(move.range(of: "deletedOccurrenceVerdict(of: series, id: seriesID, reachedFrom: nil,"))
        let firstWrite = try XCTUnwrap(move.range(of: "EventMoveExecutor.run("))
        XCTAssertLessThan(check.lowerBound, firstWrite.lowerBound)
        XCTAssertTrue(move.contains("if isRecurring, !(span == .this && occurrenceDate != nil),"))
        XCTAssertTrue(move.contains("FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: master.calendar?.source?.sourceIdentifier,"))
        XCTAssertTrue(move.contains("if verdict != .none {"))
        XCTAssertTrue(move.contains("throw EventKitError.moveRefused(reason: DeletedOccurrenceCheck.accountMoveReason(verdict))"))
    }

    func testTheVerdictListsTheSeriesAsTheAllDayCheckDoes() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "func deletedOccurrenceVerdict(", in: file))
        XCTAssertTrue(body.contains("seriesOccurrences(of: series, id: id)"))
        XCTAssertTrue(body.contains("SeriesExceptionsPlanner.listingRanges(for: window)"))
        XCTAssertTrue(body.contains("DetachedOccurrenceSpan.coversWholeSeries("))
        XCTAssertTrue(body.contains("UndoPostState.ruleSlot(of:"), "edited occurrences count by their rule slot")
        XCTAssertTrue(body.contains("DeletedOccurrenceCheck.firstSlot("), "the first slot is proven, never taken from a stand-in")
        XCTAssertTrue(body.contains("let atStart = candidates.filter { UndoPostState.sameInstant($0.start, series.startDate) }"),
                      "every occurrence at the object's own start is counted (round 3: it must be one)")
        XCTAssertTrue(body.contains("earliestListedSlot: candidates.map(ruleSlot).min()"))
        XCTAssertTrue(body.contains("uneditedSlots: candidates.filter { !$0.isDetached }.map(ruleSlot)"))
        XCTAssertTrue(body.contains("slotsTrusted: !candidates.contains { $0.isDetached && !$0.slotFromRID }"))
        XCTAssertTrue(body.contains("guard !candidates.isEmpty else { return .unknown }"), "an empty listing is not 'none deleted'")
        // PR #505 round 4 (LOW 4, 7): an all-day series' end is read with its all-day flag.
        XCTAssertTrue(body.contains("isAllDay: series.isAllDay)"))
    }
}
