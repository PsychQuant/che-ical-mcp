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
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.deletedReason"))
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.unknownReason"))
    }

    func testTheVerdictListsTheSeriesAsTheAllDayCheckDoes() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "func deletedOccurrenceVerdict(", in: file))
        XCTAssertTrue(body.contains("seriesOccurrences(of: series, id: id)"))
        XCTAssertTrue(body.contains("SeriesExceptionsPlanner.listingRanges(for: window)"))
        XCTAssertTrue(body.contains("DetachedOccurrenceSpan.coversWholeSeries("))
        XCTAssertTrue(body.contains("UndoPostState.ruleSlot(of:"), "edited occurrences count by their rule slot")
        XCTAssertTrue(body.contains("guard !candidates.isEmpty else { return .unknown }"), "an empty listing is not 'none deleted'")
    }
}
