import XCTest
@testable import CheICalMCP

/// #299: the one "Gregorian calendar in a zone" helper the reminder date code shares.
final class GregorianCalendarTests: XCTestCase {
    func testItIsGregorianInTheGivenZone() {
        let apia = TimeZone(identifier: "Pacific/Apia")!
        let calendar = Calendar.gregorian(in: apia)
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone, apia)
    }

    func testItCountsTheGregorianYear() {
        let instant = Date(timeIntervalSince1970: 1_791_595_800)   // 2026-10-10T01:30:00Z
        let calendar = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        XCTAssertEqual([fields.year, fields.month, fields.day, fields.hour, fields.minute], [2026, 10, 10, 9, 30])
    }
}
