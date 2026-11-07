import XCTest
@testable import CheICalMCP

/// #478: on a series that has started, a `timezone` or `clear_timezone` change from an occurrence
/// that has happened moved past occurrences and lost the last one (measured on iCloud: a weekly
/// series of 10 from Asia/Taipei set to Europe/London became 9). Refused before anything is written.
final class SeriesZoneChangeTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let london = TimeZone(identifier: "Europe/London")!
    private let first = Date(timeIntervalSince1970: 1_788_737_400) // 2026-09-07 07:30 +08:00

    func testAZoneChangeIsANewZoneOrClearingOne() {
        XCTAssertTrue(SeriesRuleWrite.changesZone(requested: london, clearTimezone: false, stored: taipei))
        XCTAssertFalse(SeriesRuleWrite.changesZone(requested: taipei, clearTimezone: false, stored: taipei), "the same zone echoed")
        XCTAssertTrue(SeriesRuleWrite.changesZone(requested: taipei, clearTimezone: false, stored: nil), "a zone on a floating event")
        XCTAssertFalse(SeriesRuleWrite.changesZone(requested: nil, clearTimezone: false, stored: taipei), "no zone in the call")
        XCTAssertTrue(SeriesRuleWrite.changesZone(requested: nil, clearTimezone: true, stored: taipei))
        XCTAssertFalse(SeriesRuleWrite.changesZone(requested: nil, clearTimezone: true, stored: nil), "nothing to clear")
    }

    private func refusal(_ reach: SeriesRuleWrite.Reach? = nil, happened: Bool = true, changes: Bool = true, allDay: Bool = false) -> String? {
        SeriesRuleWrite.zoneRefusal(reach: reach ?? .wholeSeries(anchor: first), happened: happened, changesZone: changes, isAllDay: allDay)
    }

    func testAStartedSeriesRefusesAZoneChange() {
        XCTAssertEqual(refusal(), SeriesRuleWrite.zoneChangeReason, "the #478 repro: span all")
        XCTAssertEqual(refusal(.fromLaterOccurrence(anchor: first)), SeriesRuleWrite.zoneChangeReason, "span future from one that happened")
    }

    func testTheShapesThatKeepWorking() {
        XCTAssertNil(refusal(happened: false), "a series still to come: measured, all 6 kept")
        XCTAssertNil(refusal(changes: false), "the same zone echoed")
        XCTAssertNil(refusal(.oneOccurrence), "span this, or a one-off event")
        XCTAssertNil(refusal(allDay: true), "an all-day event has no zone")
    }

    func testTheReasonSaysWhyAndNamesOnlyMeasuredRoutes() {
        let reason = SeriesRuleWrite.zoneChangeReason
        for phrase in ["has started", "already happened", "wall-clock time", "daylight-saving", "another day",
                       "leave timezone and clear_timezone out", "span 'future'", "has not happened yet", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
    }

    func testUpdateEventRefusesBeforeTheFirstAssignment() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        let pin = "if let reason = SeriesRuleWrite.zoneRefusal( reach: reach, happened: happened, changesZone: SeriesRuleWrite.changesZone(requested: timezone, clearTimezone: clearTimezone, stored: event.timeZone), isAllDay: datePlan.isAllDay || event.isAllDay) { throw EventKitError.seriesWriteRefused(reason: reason) }"
        let range = try XCTUnwrap(flat.range(of: pin), pin)
        XCTAssertLessThan(range.lowerBound, firstWrite.lowerBound)
    }
}
