import XCTest
@testable import CheICalMCP

/// #451: the `update_event` shapes refused because occurrences went silently, as measured on iCloud.
final class SeriesRuleWriteTests: XCTestCase {
    private let first = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86_400

    // MARK: moving the start past occurrences that happened

    private func reads(coversSeries: Bool = true, repeats: Bool = true, planned: TimeInterval, nowAfterFirst: TimeInterval = 5 * 86_400) -> Bool {
        SeriesRuleWrite.needsPassedOccurrenceCheck(coversSeries: coversSeries, repeats: repeats, firstStart: first,
                                                   plannedStart: first.addingTimeInterval(planned), now: first.addingTimeInterval(nowAfterFirst))
    }

    func testOnlyAStartMovedLaterOnAStartedSeriesIsLookedAt() {
        XCTAssertTrue(reads(planned: week))
        XCTAssertFalse(reads(planned: -week), "earlier: measured clean")
        XCTAssertFalse(reads(planned: 0), "the same start")
        XCTAssertFalse(reads(coversSeries: false, planned: week), "span future from a later occurrence: measured clean")
        XCTAssertFalse(reads(repeats: false, planned: week), "a one-off event")
        XCTAssertFalse(reads(planned: week, nowAfterFirst: -86_400), "a series that has not started loses nothing that happened")
    }

    /// One passed occurrence is enough: the first one went on a move of a week.
    func testAnOccurrenceUpToTheNewStartRefuses() {
        let second = first.addingTimeInterval(week), planned = second
        XCTAssertTrue(SeriesRuleWrite.passesAnOccurrence(starts: [first, second, second.addingTimeInterval(week)], firstStart: first, plannedStart: planned))
        XCTAssertFalse(SeriesRuleWrite.passesAnOccurrence(starts: [first, second], firstStart: first, plannedStart: first.addingTimeInterval(2 * 86_400)),
                       "two days later, before the second: measured clean")
        XCTAssertFalse(SeriesRuleWrite.passesAnOccurrence(starts: [first], firstStart: first, plannedStart: planned))
        XCTAssertFalse(SeriesRuleWrite.passesAnOccurrence(starts: [], firstStart: first, plannedStart: planned))
    }

    func testTheStartReasonNamesTheRouteThatWasMeasured() {
        let reason = SeriesRuleWrite.startPassesOccurrencesReason
        for phrase in ["already happened", "span 'future'", "occurrence_date", "start_time", "end_date", "Nothing was written."] {
            XCTAssertTrue(reason.contains(phrase), "\(phrase): \(reason)")
        }
    }

    // MARK: span future from a later occurrence

    private func refusal(later: Bool = true, allDay: Bool = false, calendar: Bool = false, rule: Bool = false, count: Int? = nil) -> String? {
        SeriesRuleWrite.laterOccurrenceRefusal(fromLaterOccurrence: later, changesAllDay: allDay, changesCalendar: calendar,
                                               hasRecurrence: rule, occurrenceCount: count)
    }

    func testAllDayIsRefusedWithOrWithoutARule() {
        XCTAssertEqual(refusal(allDay: true), SeriesRuleWrite.allDayReason)
        XCTAssertEqual(refusal(allDay: true, rule: true), SeriesRuleWrite.allDayReason)
        XCTAssertEqual(refusal(allDay: true, rule: true, count: 4), SeriesRuleWrite.allDayReason)
    }

    func testACountIsRefused() {
        XCTAssertEqual(refusal(rule: true, count: 4), SeriesRuleWrite.countReason)
        XCTAssertEqual(refusal(calendar: true, rule: true, count: 4), SeriesRuleWrite.countReason)
    }

    /// With a rule the calendar change stayed within the later occurrences; alone it moved all of them.
    func testACalendarAloneIsRefusedAndWithARuleIsNot() {
        XCTAssertEqual(refusal(calendar: true), SeriesRuleWrite.calendarReason)
        XCTAssertNil(refusal(calendar: true, rule: true))
    }

    func testTheCleanShapesPass() {
        XCTAssertNil(refusal())
        XCTAssertNil(refusal(rule: true), "a rule with end_date or no bound")
        XCTAssertNil(refusal(later: false, allDay: true, calendar: true, rule: true, count: 4), "not from a later occurrence")
    }

    func testTheReasonsSayWhatWasMeasuredAndNothingWasWritten() {
        XCTAssertTrue(SeriesRuleWrite.countReason.contains("end_date"), SeriesRuleWrite.countReason)
        XCTAssertTrue(SeriesRuleWrite.calendarReason.contains("span 'all'"), SeriesRuleWrite.calendarReason)
        XCTAssertTrue(SeriesRuleWrite.allDayReason.contains("span 'all'"), SeriesRuleWrite.allDayReason)
        for reason in [SeriesRuleWrite.countReason, SeriesRuleWrite.calendarReason, SeriesRuleWrite.allDayReason] {
            XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
        }
    }

    // MARK: wiring (no in-memory store can run updateEvent)

    func testUpdateEventRefusesBeforeTheFirstAssignment() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let later = try XCTUnwrap(flat.range(of: "SeriesRuleWrite.laterOccurrenceRefusal( fromLaterOccurrence: !applyToAll && span == .futureEvents && event !== masterEvent && event.startDate > masterEvent.startDate,"))
        let start = try XCTUnwrap(flat.range(of: "SeriesRuleWrite.needsPassedOccurrenceCheck( coversSeries: applyToAll || (span == .futureEvents && event.startDate == masterEvent.startDate),"))
        let firstWrite = try XCTUnwrap(flat.range(of: "if let t = title { event.title = t }"))
        XCTAssertLessThan(later.lowerBound, firstWrite.lowerBound)
        XCTAssertLessThan(start.lowerBound, firstWrite.lowerBound)
        XCTAssertTrue(flat.contains("throw EventKitError.seriesWriteRefused(reason: SeriesRuleWrite.startPassesOccurrencesReason)"))
    }
}
