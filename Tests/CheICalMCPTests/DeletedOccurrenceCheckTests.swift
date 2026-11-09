import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// #503: a write that changes the start, end or all-day flag of more than one occurrence of a
/// series brought back every occurrence deleted on its own (iCloud, measured). The check compares
/// the rule's expected slots with the listed occurrences and refuses when one is missing, or when
/// it cannot tell (`unknown`). Pure: no store.
final class DeletedOccurrenceCheckTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Taipei")!
    private var calendar: Calendar { Calendar.gregorian(in: zone) }

    private func at(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.date(from: text + "+08:00")!
    }

    private func weekly(days: [Int] = [], interval: Int = 1, count: Int = 0, end: Date? = nil) -> DeletedOccurrenceCheck.Rule {
        .init(frequency: .weekly, interval: interval, daysOfWeek: days, daysOfMonth: [], endDate: end, occurrenceCount: count, hasOtherParts: false)
    }

    // MARK: - Expected slots

    func testAWeeklyRuleGivesOneSlotAWeek() throws {
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(count: 5), firstStart: at("2026-12-07T10:00:00"),
                                                                        until: at("2027-12-31T00:00:00"), calendar: calendar))
        XCTAssertEqual(slots, ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"].map { at($0 + "T10:00:00") })
    }

    func testAWeeklyRuleOnSeveralDaysCountsFromTheFirstStart() throws {
        // Monday and Wednesday from a Monday, three occurrences.
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(days: [2, 4], count: 3), firstStart: at("2026-12-07T10:00:00"),
                                                                        until: at("2027-12-31T00:00:00"), calendar: calendar))
        XCTAssertEqual(slots, [at("2026-12-07T10:00:00"), at("2026-12-09T10:00:00"), at("2026-12-14T10:00:00")])
    }

    func testAnEndDateBoundsTheSlots() throws {
        let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: weekly(end: at("2026-12-21T23:59:00")), firstStart: at("2026-12-07T10:00:00"),
                                                                        until: at("2027-12-31T00:00:00"), calendar: calendar))
        XCTAssertEqual(slots.count, 3)
    }

    func testDailyMonthlyAndYearlyRules() throws {
        let first = at("2026-01-31T09:00:00")
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 2, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 3, hasOtherParts: false)
        XCTAssertEqual(DeletedOccurrenceCheck.expectedSlots(of: daily, firstStart: first, until: at("2027-12-31T00:00:00"), calendar: calendar),
                       [at("2026-01-31T09:00:00"), at("2026-02-02T09:00:00"), at("2026-02-04T09:00:00")])
        // The 31st skips months without one, as RFC 5545 does.
        let monthly = DeletedOccurrenceCheck.Rule(frequency: .monthly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 3, hasOtherParts: false)
        XCTAssertEqual(DeletedOccurrenceCheck.expectedSlots(of: monthly, firstStart: first, until: at("2027-12-31T00:00:00"), calendar: calendar),
                       [at("2026-01-31T09:00:00"), at("2026-03-31T09:00:00"), at("2026-05-31T09:00:00")])
        let yearly = DeletedOccurrenceCheck.Rule(frequency: .yearly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 2, hasOtherParts: false)
        XCTAssertEqual(DeletedOccurrenceCheck.expectedSlots(of: yearly, firstStart: first, until: at("2028-12-31T00:00:00"), calendar: calendar),
                       [at("2026-01-31T09:00:00"), at("2027-01-31T09:00:00")])
    }

    /// Rules the expander cannot follow give nil, which the verdict reads as unknown.
    func testRulesTheExpanderCannotFollow() {
        let first = at("2026-12-07T10:00:00"), until = at("2027-12-31T00:00:00")
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(of: weekly(days: [2, 4], interval: 2), firstStart: first, until: until, calendar: calendar),
                     "several days every two weeks depend on the week start")
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(of: weekly(days: [3]), firstStart: first, until: until, calendar: calendar),
                     "a first start off the rule's days")
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: true),
            firstStart: first, until: until, calendar: calendar))
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .monthly, interval: 1, daysOfWeek: [], daysOfMonth: [-1], endDate: nil, occurrenceCount: 0, hasOtherParts: false),
            firstStart: first, until: until, calendar: calendar))
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .yearly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: false),
            firstStart: at("2028-02-29T10:00:00"), until: until, calendar: calendar))
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(
            of: .init(frequency: .daily, interval: 1, daysOfWeek: [2], daysOfMonth: [], endDate: nil, occurrenceCount: 0, hasOtherParts: false),
            firstStart: first, until: until, calendar: calendar))
    }

    // MARK: - Verdict

    private func verdict(observed: [String], reachedFrom: String = "2026-12-07T10:00:00", covers: Bool = true,
                         rules: [DeletedOccurrenceCheck.Rule]? = nil) -> DeletedOccurrenceCheck.Verdict {
        DeletedOccurrenceCheck.verdict(rules: rules ?? [weekly(count: 5)], firstStart: at("2026-12-07T10:00:00"),
                                       observedSlots: observed.map { at($0 + "T10:00:00") }, reachedFrom: at(reachedFrom),
                                       scannedTo: at("2027-12-31T00:00:00"), coversWholeSeries: covers, calendar: calendar)
    }

    func testAMissingSlotIsADeletedOccurrence() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"]), .deleted)
    }

    func testEverySlotListedIsNone() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"]), .none)
    }

    func testOnlyTheSlotsTheWriteReachesCount() {
        // Span future from the third occurrence: the deleted second is not reached (#503: it stayed deleted).
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"], reachedFrom: "2026-12-21T10:00:00"), .none)
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2027-01-04"], reachedFrom: "2026-12-21T10:00:00"), .deleted)
    }

    func testASeriesTheListingDoesNotCoverIsUnknown() {
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"], covers: false), .unknown)
        // A deletion found inside the listing refuses on its own grounds.
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-21", "2026-12-28", "2027-01-04"], covers: false), .deleted)
    }

    func testMoreThanOneRuleOrAnUnfollowableRuleIsUnknown() {
        XCTAssertEqual(verdict(observed: [], rules: [weekly(count: 5), weekly(count: 5)]), .unknown)
        XCTAssertEqual(verdict(observed: [], rules: []), .unknown)
        XCTAssertEqual(verdict(observed: ["2026-12-07"], rules: [weekly(days: [3])]), .unknown)
    }

    func testAnEditedOccurrenceIsListedByItsRuleSlot() {
        // The caller passes rule slots; an occurrence moved to 11:00 is listed at its 10:00 slot.
        XCTAssertEqual(verdict(observed: ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"]), .none)
    }

    // MARK: - When the check applies

    func testTheCheckAppliesToWritesThatChangeTheDatesOfMoreThanOneOccurrence() {
        let start = at("2026-12-07T10:00:00"), end = at("2026-12-07T11:00:00")
        func applies(_ reachesSeveral: Bool, newStart: Date? = nil, newEnd: Date? = nil, allDay: Bool = false, clearing: Bool = false) -> Bool {
            DeletedOccurrenceCheck.applies(reachesSeveral: reachesSeveral, clearingRecurrence: clearing,
                                           plannedDates: newStart.map { ($0, newEnd ?? end) } ?? newEnd.map { (start, $0) },
                                           storedStart: start, storedEnd: end, resultAllDay: allDay, storedAllDay: false)
        }
        XCTAssertTrue(applies(true, newStart: at("2026-12-07T11:00:00"), newEnd: at("2026-12-07T12:00:00")))
        XCTAssertTrue(applies(true, newEnd: at("2026-12-07T11:30:00")), "an end-only change brought it back")
        XCTAssertTrue(applies(true, allDay: true))
        XCTAssertFalse(applies(true, newStart: start, newEnd: end), "the stored values kept it")
        XCTAssertFalse(applies(true), "a title-only write kept it")
        XCTAssertFalse(applies(false, newStart: at("2026-12-07T11:00:00")), "one occurrence")
        XCTAssertFalse(applies(true, newStart: at("2026-12-07T11:00:00"), clearing: true), "clear_recurrence leaves one event")
    }

    func testTheRefusalTextsNameTheIssueAndWriteNothing() {
        for reason in [DeletedOccurrenceCheck.deletedReason, DeletedOccurrenceCheck.unknownReason] {
            XCTAssertTrue(reason.contains("Nothing was written."), reason)
            XCTAssertTrue(reason.contains("deleted on its own"), reason)
        }
        XCTAssertTrue(DeletedOccurrenceCheck.deletedReason.contains("span 'future'"))
    }
}
