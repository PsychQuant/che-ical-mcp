import XCTest
@testable import CheICalMCP

/// #364 verify round 1: create_event's idempotency check searches events overlapping a minute
/// around the start. After all-day normalization the start is midnight, so a same-titled all-day
/// event on the PREVIOUS day (ending 23:59:59) overlaps that window. For an all-day create the
/// match must be an all-day event that starts on the same day; a timed create keeps the title rule.
final class CreateDuplicateKeyTests: XCTestCase {
    private let cal = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)
    private func day(_ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2027, month: 2, day: d, hour: h))!
    }

    func testAnAllDayEventOnThePreviousDayIsNotADuplicate() {
        XCTAssertFalse(EventKitManager.isCreateDuplicate(
            title: "WFH", start: day(11), isAllDay: true,
            candidateTitle: "WFH", candidateStart: day(10), candidateAllDay: true))
    }

    func testAnAllDayEventOnTheSameDayIsADuplicate() {
        XCTAssertTrue(EventKitManager.isCreateDuplicate(
            title: "WFH", start: day(11), isAllDay: true,
            candidateTitle: "WFH", candidateStart: day(11), candidateAllDay: true))
    }

    func testATimedEventAtMidnightIsNotAnAllDayDuplicate() {
        XCTAssertFalse(EventKitManager.isCreateDuplicate(
            title: "WFH", start: day(11), isAllDay: true,
            candidateTitle: "WFH", candidateStart: day(11), candidateAllDay: false))
    }

    func testATimedCreateKeepsTheTitleRule() {
        XCTAssertTrue(EventKitManager.isCreateDuplicate(
            title: "Sync", start: day(11, 9), isAllDay: false,
            candidateTitle: "Sync", candidateStart: day(11, 9), candidateAllDay: false))
        XCTAssertFalse(EventKitManager.isCreateDuplicate(
            title: "Sync", start: day(11, 9), isAllDay: false,
            candidateTitle: "Other", candidateStart: day(11, 9), candidateAllDay: false))
    }

    /// #364 verify round 2: a timed create used to match a same-titled ALL-DAY event that covers
    /// its start (any all-day event on that day overlaps the search window) and create nothing.
    func testATimedCreateDoesNotMatchAnAllDayEvent() {
        XCTAssertFalse(EventKitManager.isCreateDuplicate(
            title: "Conference", start: day(11, 9), isAllDay: false,
            candidateTitle: "Conference", candidateStart: day(11), candidateAllDay: true))
    }

    /// The rule is only worth something if createEvent passes the request's all-day flag to it.
    func testCreateEventPassesItsAllDayFlagToTheDuplicateCheck() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        // Whitespace-insensitive and bounded by the next `func`, so reformatting does not break it.
        let source = try String(contentsOf: url, encoding: .utf8)
        func body(_ name: String) throws -> String {
            let from = try XCTUnwrap(source.range(of: name), name)
            let rest = source[from.upperBound...]
            let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
            return rest[..<end].filter { !$0.isWhitespace }
        }
        XCTAssertTrue(try body("func createEvent(")
            .contains("findDuplicateEvent(title:title,startDate:startDate,isAllDay:isAllDay,calendar:calendar)"))
        XCTAssertTrue(try body("private func findDuplicateEvent(").contains("Self.isCreateDuplicate("))
    }
}
