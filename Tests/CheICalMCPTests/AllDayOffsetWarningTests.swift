import XCTest
@testable import CheICalMCP

/// #372: an all-day date written with an offset whose day differs from its day in the host zone
/// is reported in the response (the event is still written with the host-zone day, #364 D2).
final class AllDayOffsetWarningTests: XCTestCase {
    private let taipei = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)

    /// The date the handler would parse: a full ISO value keeps its own offset, any other form is
    /// read in `calendar`'s zone (all-day calls cannot carry `timezone`, #190).
    private func date(_ text: String, _ calendar: Calendar) throws -> Date {
        try FlexibleDate.parse(text, defaultTimezone: calendar.timeZone, iso: ISO8601DateFormatter())
    }

    private func warnings(start: String, end: String, host: Calendar? = nil) throws -> [AllDayOffsetWarning.Warning] {
        let host = host ?? taipei
        return AllDayOffsetWarning.warnings(start: try date(start, host), startText: start,
                                            end: try date(end, host), endText: end, host: host)
    }

    // MARK: - written offset

    private func offset(_ text: String) throws -> Int? {
        AllDayOffsetWarning.writtenOffset(text, parsed: try date(text, taipei))?.secondsFromGMT()
    }

    /// The offset is what the server's parser applied, read back from the parsed instant, so every
    /// form `ISO8601DateFormatter` accepts counts (verify round 2: `+07`, `UTC`, `GMT+7`, `z`).
    func testWrittenOffsetIsTheOneTheParserApplied() throws {
        let cases: [(String, Int)] = [
            ("2027-04-11T23:59:59+07:00", 7 * 3600), ("2027-04-11T23:59:59-05:30", -(5 * 3600 + 1800)),
            ("2027-04-11T23:59:59+0700", 7 * 3600), ("2027-04-11T23:59:59+07", 7 * 3600),
            ("2027-04-11T23:59:59Z", 0), ("2027-04-11T23:59:59z", 0), ("2027-04-11T23:59:59UTC", 0),
            ("2027-04-11T23:59:59GMT+7", 7 * 3600), ("2027-04-11T23:59:59GMT+07:00", 7 * 3600),
        ]
        for (text, seconds) in cases {
            XCTAssertEqual(try offset(text), seconds, text)
        }
    }

    func testAValueWithoutAnOffsetHasNone() throws {
        for text in ["2027-04-11", "2027-04-11T23:59:59", "14:00", "14:00:00"] {
            XCTAssertNil(try offset(text), text)
        }
    }

    /// A `UTC`-suffixed end moves the day like `Z` does.
    func testAUTCSuffixWarnsLikeZ() throws {
        XCTAssertEqual(try warnings(start: "2027-04-10", end: "2027-04-11T20:00:00UTC"),
                       [.init(field: "end_time", writtenDay: "2027-04-11", hostDay: "2027-04-12")])
    }

    // MARK: - warnings

    func testTheIssuesExampleWarnsOnTheEnd() throws {
        let result = try warnings(start: "2027-04-10", end: "2027-04-11T23:59:59+07:00")
        XCTAssertEqual(result, [.init(field: "end_time", writtenDay: "2027-04-11", hostDay: "2027-04-12")])
    }

    /// The date prefix agrees (04-12), but in the written zone it is an exclusive midnight (last day
    /// 04-11) and in the host zone 01:00, an inclusive 04-12.
    func testAnExclusiveMidnightInTheWrittenZoneWarns() throws {
        let result = try warnings(start: "2027-04-10", end: "2027-04-12T00:00:00+07:00")
        XCTAssertEqual(result, [.init(field: "end_time", writtenDay: "2027-04-11", hostDay: "2027-04-12")])
    }

    func testAUTCStartThatFallsOnTheNextHostDayWarns() throws {
        let result = try warnings(start: "2027-04-10T20:00:00Z", end: "2027-04-12")
        XCTAssertEqual(result, [.init(field: "start_time", writtenDay: "2027-04-10", hostDay: "2027-04-11")])
    }

    func testBothEndsAreReportedStartFirst() throws {
        let result = try warnings(start: "2027-04-10T23:30:00+07:00", end: "2027-04-11T23:30:00+07:00")
        XCTAssertEqual(result.map(\.field), ["start_time", "end_time"])
        XCTAssertEqual(result.map(\.writtenDay), ["2027-04-10", "2027-04-11"])
        XCTAssertEqual(result.map(\.hostDay), ["2027-04-11", "2027-04-12"])
    }

    func testValuesWithoutAnOffsetNeverWarn() throws {
        XCTAssertEqual(try warnings(start: "2027-04-10", end: "2027-04-12"), [])
        XCTAssertEqual(try warnings(start: "2027-04-10T23:30:00", end: "2027-04-11T23:59:59"), [])
    }

    func testAnOffsetWhoseDayAgreesDoesNotWarn() throws {
        XCTAssertEqual(try warnings(start: "2027-04-10T09:00:00+07:00", end: "2027-04-11T12:00:00+07:00"), [])
    }

    func testTheHostsOwnOffsetDoesNotWarn() throws {
        XCTAssertEqual(try warnings(start: "2027-04-10T00:00:00+08:00", end: "2027-04-11T23:59:59+08:00"), [])
        XCTAssertEqual(try warnings(start: "2027-04-10T00:00:00+08:00", end: "2027-04-12T00:00:00+08:00"), [])
    }

    /// The host's offset on the event's date counts, not today's: `-04:00` is New York in July.
    func testTheHostOffsetOnTheEventsDateIsUsed() throws {
        let newYork = Calendar.gregorian(in: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(try warnings(start: "2027-07-01", end: "2027-07-01T23:59:59-04:00", host: newYork), [])
        XCTAssertEqual(try warnings(start: "2027-07-01", end: "2027-07-01T23:59:59-05:00", host: newYork),
                       [.init(field: "end_time", writtenDay: "2027-07-01", hostDay: "2027-07-02")])
    }

    /// `update_event` with only `end_time`: the first day is the saved event's (host) start.
    func testAnEndOnlyUpdateUsesTheSavedStart() throws {
        let savedStart = taipei.startOfDay(for: try date("2027-04-10", taipei))
        let end = "2027-04-11T23:59:59+07:00"
        let result = AllDayOffsetWarning.warnings(start: savedStart, startText: nil,
                                                  end: try date(end, taipei), endText: end, host: taipei)
        XCTAssertEqual(result, [.init(field: "end_time", writtenDay: "2027-04-11", hostDay: "2027-04-12")])
    }

    /// `update_event` with only `start_time`: the end is not the call's, so it is not checked.
    func testAStartOnlyUpdateChecksOnlyTheStart() throws {
        let start = "2027-04-10T23:30:00+07:00"
        let result = AllDayOffsetWarning.warnings(start: try date(start, taipei), startText: start,
                                                  end: try date("2027-04-12T00:30:00+07:00", taipei), endText: nil,
                                                  host: taipei)
        XCTAssertEqual(result.map(\.field), ["start_time"])
    }

    func testTheDictionaryNamesTheFieldTheTwoDaysAndTheHostZone() {
        let warning = AllDayOffsetWarning.Warning(field: "end_time", writtenDay: "2027-04-11", hostDay: "2027-04-12")
        let dictionary = warning.dictionary(hostZone: TimeZone(identifier: "Asia/Taipei")!)
        XCTAssertEqual(dictionary["field"] as? String, "end_time")
        XCTAssertEqual(dictionary["written_day"] as? String, "2027-04-11")
        XCTAssertEqual(dictionary["host_day"] as? String, "2027-04-12")
        let message = try? XCTUnwrap(dictionary["message"] as? String)
        XCTAssertTrue(message?.contains("Asia/Taipei") == true, message ?? "")
        XCTAssertTrue(message?.contains("2027-04-12") == true, message ?? "")
        XCTAssertEqual(Set(dictionary.keys), ["field", "written_day", "host_day", "message"])
    }

    func testResponseFieldsAreEmptyWithoutWarnings() {
        XCTAssertTrue(AllDayOffsetWarning.responseFields([], hostZone: .current).isEmpty)
        let fields = AllDayOffsetWarning.responseFields(
            [.init(field: "start_time", writtenDay: "2027-04-10", hostDay: "2027-04-11")], hostZone: .current)
        XCTAssertEqual((fields["warnings"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - #372 verify: the hint re-sent gives the written day

    /// Following the end hint must keep the written last day: a bare date as end_time after the
    /// first day is an exclusive end, so the hint offers `<day>T23:59:59` or the day after.
    func testTheEndHintsResentThroughTheAllDayRuleEndOnTheWrittenDay() throws {
        for (start, end) in [("2027-04-10", "2027-04-11T23:59:59+07:00"), ("2027-04-10", "2027-04-12T00:00:00+07:00"),
                             ("2027-04-11", "2027-04-11T23:59:59+07:00")] {
            let warning = try XCTUnwrap(try warnings(start: start, end: end).first { $0.field == "end_time" })
            XCTAssertEqual(warning.suggestedValues.count, 2)
            let first = try date(start, taipei)
            for value in warning.suggestedValues {
                XCTAssertNil(try offset(value), value)
                let resent = try date(value, taipei)
                let created = try AllDayRange.normalize(start: first, end: resent, calendar: taipei)
                XCTAssertEqual(dayString(created.end), warning.writtenDay, "create with \(value)")
                let updated = try AllDayRange.planUpdate(
                    storedStart: created.start, storedEnd: created.end, storedAllDay: true,
                    newStart: nil, newEnd: resent, requestedAllDay: nil, calendar: taipei)
                XCTAssertEqual(dayString(updated.end), warning.writtenDay, "update with \(value)")
            }
            XCTAssertTrue(warning.dictionary(hostZone: taipei.timeZone)["message"].map { "\($0)" }?
                .contains(warning.suggestedValues[0]) == true)
        }
    }

    func testTheStartHintResentStartsOnTheWrittenDay() throws {
        let warning = try XCTUnwrap(try warnings(start: "2027-04-10T20:00:00Z", end: "2027-04-12").first)
        XCTAssertEqual(warning.suggestedValues, ["2027-04-10"])
        let resent = try date(warning.suggestedValues[0], taipei)
        let created = try AllDayRange.normalize(start: resent, end: try date("2027-04-12", taipei), calendar: taipei)
        XCTAssertEqual(dayString(created.start), warning.writtenDay)
    }

    /// The old advice, a bare `written_day` as end_time, drops that day: the case the hint avoids.
    func testABareWrittenDayAsEndWouldDropIt() throws {
        let first = try date("2027-04-10", taipei)
        let created = try AllDayRange.normalize(start: first, end: try date("2027-04-11", taipei), calendar: taipei)
        XCTAssertEqual(dayString(created.end), "2027-04-10")
    }

    private func dayString(_ date: Date) -> String {
        let parts = taipei.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Verify round 3: a skipped duplicate keeps its existing dates, so the message speaks of the
    /// request's dates and says the existing event was not changed.
    func testASkippedCreatesMessageSpeaksOfTheRequestsDates() {
        let zone = TimeZone(identifier: "Asia/Taipei")!
        for (field, verb) in [("end_time", "ending"), ("start_time", "starting")] {
            let warning = AllDayOffsetWarning.Warning(field: field, writtenDay: "2027-04-11", hostDay: "2027-04-12")
            let skipped = warning.dictionary(hostZone: zone, skipped: true)["message"] as? String ?? ""
            XCTAssertTrue(skipped.contains("the request's dates would be written \(verb) on 2027-04-12"), skipped)
            XCTAssertTrue(skipped.contains("the existing event was not changed"), skipped)
            XCTAssertFalse(skipped.contains("the event \(verb == "ending" ? "ends" : "starts") on"), skipped)
            let written = warning.dictionary(hostZone: zone)["message"] as? String ?? ""
            XCTAssertFalse(written.contains("not changed"), written)
        }
        let fields = AllDayOffsetWarning.responseFields(
            [.init(field: "end_time", writtenDay: "2027-04-11", hostDay: "2027-04-12")], hostZone: zone, skipped: true)
        let message = (fields["warnings"] as? [[String: Any]])?.first?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("not changed"), message)
    }
}

