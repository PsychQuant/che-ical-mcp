import XCTest
@testable import CheICalMCP

/// #543: `occurrenceDateMatches` reads an `EKEvent` and the series object from the store, which no
/// unit test can run. These pins read the source; the comparison itself is `OccurrenceDateMatchTests`.
final class OccurrenceDateMatchWiringTests: XCTestCase {
    private func body() throws -> String {
        let source = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        return try XCTUnwrap(SourcePins.body(of: "func occurrenceDateMatches(", in: source))
    }

    /// The check goes through the pure comparison once, with this Mac's zone as the host.
    func testOccurrenceDateMatchesCallsThePureComparisonWithTheHostZone() throws {
        let check = try body()
        XCTAssertEqual(SourcePins.ranges(of: "OccurrenceDateMatch.matches(", in: check).count, 1)
        XCTAssertTrue(check.contains("host: .current"))
        XCTAssertTrue(check.contains("requested: date, start: occurrence.startDate, startIsAllDay: occurrence.isAllDay"))
        XCTAssertTrue(check.contains("zone: Self.occurrenceZone(of: occurrence)"))
        XCTAssertTrue(check.contains("eventIdentifier: id, externalIdentifier: occurrence.calendarItemExternalIdentifier"))
        XCTAssertTrue(check.contains("occurrenceDate: occurrence.occurrenceDate"))
        // The raw reading is no longer made here.
        XCTAssertTrue(SourcePins.ranges(of: "originalSlot(", in: check).isEmpty)
        XCTAssertTrue(SourcePins.ranges(of: "startsOnRequestedDay(", in: check).isEmpty)
    }

    // spec-example: occurrence-date-own-identifier / The series object cannot be read
    /// The series' flag comes from the series object the identifier names, the occurrence's own flag
    /// when that object cannot be read (none, or the lookup throws).
    func testTheSeriesFlagComesFromTheSeriesObjectWithTheOccurrencesAsFallback() throws {
        let check = try body()
        XCTAssertTrue(check.contains("let seriesIsAllDay = (try? seriesObject(ofOccurrence: id))?.isAllDay ?? occurrence.isAllDay"))
        XCTAssertTrue(check.contains("seriesIsAllDay: seriesIsAllDay"))
    }

    /// The pure comparison reads the original slot with the series' flag in the host zone, and
    /// compares it with that flag; the shown start keeps the occurrence's own flag.
    func testThePureComparisonReadsTheSlotWithTheSeriesFlagInTheHostZone() throws {
        let source = SourcePins.code(try SourcePins.source("EventKit/OccurrenceDateMatch.swift"))
        let matches = try XCTUnwrap(SourcePins.body(of: "static func matches(", in: source))
        XCTAssertTrue(matches.contains("UndoPostState.ruleSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,"))
        XCTAssertTrue(matches.contains("occurrenceDate: occurrenceDate, isAllDay: seriesIsAllDay, zone: host)"))
        XCTAssertTrue(SourcePins.ranges(of: "originalSlot(", in: matches).isEmpty)
        XCTAssertEqual(SourcePins.ranges(of: "host: host", in: matches).count, 2)
    }
}
