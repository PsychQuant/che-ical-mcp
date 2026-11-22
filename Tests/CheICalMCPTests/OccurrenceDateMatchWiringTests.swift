import XCTest
@testable import CheICalMCP

/// #543: `occurrenceDateAnswer` reads an `EKEvent`, which no
/// unit test can run. These pins read the source; the comparison itself is `OccurrenceDateMatchTests`
/// and `OccurrenceDateMatchCellTests`.
final class OccurrenceDateMatchWiringTests: XCTestCase {
    private func body(_ signature: String) throws -> String {
        let source = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        return try XCTUnwrap(SourcePins.body(of: signature, in: source))
    }

    /// The check goes through the pure comparison once, with this Mac's zone as the host.
    func testOccurrenceDateAnswerCallsThePureComparisonWithTheHostZone() throws {
        let check = try body("func occurrenceDateAnswer(")
        XCTAssertEqual(SourcePins.ranges(of: "OccurrenceDateMatch.answer(", in: check).count, 1)
        XCTAssertTrue(check.contains("host: .current"))
        XCTAssertTrue(check.contains("requested: date, start: occurrence.startDate, startIsAllDay: occurrence.isAllDay"))
        XCTAssertTrue(check.contains("zone: Self.occurrenceZone(of: occurrence)"))
        XCTAssertTrue(check.contains("eventIdentifier: id, externalIdentifier: occurrence.calendarItemExternalIdentifier"))
        XCTAssertTrue(check.contains("occurrenceDate: occurrence.occurrenceDate"))
        XCTAssertTrue(check.contains("guard let date else { return .matches }"))
        // The raw reading is not made here.
        XCTAssertTrue(SourcePins.ranges(of: "originalSlot(", in: check).isEmpty)
        XCTAssertTrue(SourcePins.ranges(of: "startsOnRequestedDay(", in: check).isEmpty)
    }

    /// Both series origins use the same matcher without reading the current series flag.
    func testOccurrenceDateAnswerDoesNotLookUpTheSeries() throws {
        let check = try body("func occurrenceDateAnswer(")
        XCTAssertTrue(SourcePins.ranges(of: "seriesObject(ofOccurrence:", in: check).isEmpty)
        XCTAssertTrue(SourcePins.ranges(of: "seriesIsAllDay", in: check).isEmpty)
    }

    /// `occurrenceDateMatches` is the answer `.matches`, and the refusal's reason is read from the
    /// same answer at both call sites.
    func testTheMatchAndTheRefusalReasonComeFromTheAnswer() throws {
        let matches = try body("func occurrenceDateMatches(")
        XCTAssertTrue(matches.contains("occurrenceDateAnswer(date, occurrence: occurrence, id: id) == .matches"), matches)
        let refusal = try body("func occurrenceDateRefusal(")
        let call = refusal.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(call.contains("DetachedOccurrenceSpan.occurrenceDateReason( for: occurrenceDateAnswer(date, occurrence: occurrence, id: id), start: occurrence.startDate, startIsAllDay: occurrence.isAllDay, zone: Self.occurrenceZone(of: occurrence), host: .current)"), refusal)
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        XCTAssertEqual(SourcePins.ranges(of: "throw EventKitError.occurrenceAddressRefused(reason: occurrenceDateRefusal(occurrenceDate, occurrence: masterEvent, id: identifier))", in: manager).count, 2)
        XCTAssertTrue(SourcePins.ranges(of: "reason: DetachedOccurrenceSpan.occurrenceDateReason)", in: manager).isEmpty)
    }
}
