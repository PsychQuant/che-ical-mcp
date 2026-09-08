import XCTest
import EventKit
@testable import CheICalMCP

final class ReminderRecurrenceTests: XCTestCase {
    func testFullRuleRetainsSelectorsAndWeekdayOrdinals() throws {
        let rule = EKRecurrenceRule(recurrenceWith: .yearly, interval: 2,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday, weekNumber: -1)],
            daysOfTheMonth: [1, -1], monthsOfTheYear: [3, 9],
            weeksOfTheYear: [10, -2], daysOfTheYear: [100, -1],
            setPositions: [1, -1], end: EKRecurrenceEnd(occurrenceCount: 8))
        let json = ReminderRecurrenceRuleValue(from: rule).dictionary
        XCTAssertEqual(json["frequency"] as? String, "yearly")
        XCTAssertEqual(json["interval"] as? Int, 2)
        XCTAssertEqual(json["days_of_week"] as? [Int], [2])
        XCTAssertEqual(json["days_of_week_details"] as? [[String: Int]], [["day": 2, "week_number": -1]])
        XCTAssertEqual(json["days_of_month"] as? [Int], [1, -1])
        XCTAssertEqual(json["months_of_year"] as? [Int], [3, 9])
        XCTAssertEqual(json["weeks_of_year"] as? [Int], [10, -2])
        XCTAssertEqual(json["days_of_year"] as? [Int], [100, -1])
        XCTAssertEqual(json["set_positions"] as? [Int], [1, -1])
        XCTAssertEqual(json["occurrence_count"] as? Int, 8)
        XCTAssertEqual(json["calendar_identifier"] as? String, rule.calendarIdentifier)
        XCTAssertEqual(json["first_day_of_week"] as? Int, rule.firstDayOfTheWeek)
        XCTAssertTrue(json["end_date"] is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: json))
    }

    func testUnboundedAndDateBoundedRules() {
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        let snapshot = ReminderRecurrenceRuleValue(from: rule)
        XCTAssertTrue(snapshot.dictionary["days_of_week"] is NSNull)
        XCTAssertTrue(snapshot.dictionary["occurrence_count"] is NSNull)
        rule.recurrenceEnd = EKRecurrenceEnd(end: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(snapshot.dictionary["end_date"] is NSNull, "Snapshot must not retain mutable EventKit objects")
        XCTAssertEqual(ReminderRecurrenceRuleValue(from: rule).dictionary["end_date"] as? String, "1970-01-01T00:00:00Z")
    }

    private func due(_ year: Int = 2026, _ month: Int = 9, _ day: Int = 5,
                     hour: Int? = nil, minute: Int? = nil, zone: String? = nil) -> ReminderDueValue? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute
        c.timeZone = zone.flatMap(TimeZone.init(identifier:))
        return ReminderDueValue(components: c)
    }

    func testDateOnlyAndFloatingDoNotInventAbsoluteDateTimes() throws {
        let dateOnly = try XCTUnwrap(due(zone: "Asia/Tokyo"))
        XCTAssertEqual(dateOnly.dictionary["date"] as? String, "2026-09-05")
        XCTAssertTrue(dateOnly.dictionary["time"] is NSNull)
        XCTAssertTrue(dateOnly.dictionary["date_time"] is NSNull)
        let floating = try XCTUnwrap(due(hour: 12, minute: 30))
        XCTAssertEqual(floating.dictionary["time"] as? String, "12:30:00")
        XCTAssertTrue(floating.dictionary["timezone"] is NSNull)
        XCTAssertTrue(floating.dictionary["date_time"] is NSNull)
        XCTAssertNotNil(floating.chronologicalDate)
    }

    func testZonedDateTimeIsUTCAndDSTIsNotSilentlyNormalized() throws {
        XCTAssertEqual(try XCTUnwrap(due(hour: 12, minute: 30, zone: "Asia/Tokyo")).dictionary["date_time"] as? String,
                       "2026-09-05T03:30:00Z")
        for value in [due(2026, 3, 8, hour: 2, minute: 30, zone: "America/New_York"),
                      due(2026, 11, 1, hour: 1, minute: 30, zone: "America/New_York")] {
            let value = try XCTUnwrap(value)
            XCTAssertNil(value.chronologicalDate)
            XCTAssertTrue(value.dictionary["date_time"] is NSNull)
        }
    }

    func testDueComparisonDoesNotMixPrecisionOrTimeZones() throws {
        let floating = try XCTUnwrap(due(hour: 12, minute: 30))
        XCTAssertFalse(floating.hasSamePrecisionAndTimeZone(as: try XCTUnwrap(due())))
        XCTAssertFalse(floating.hasSamePrecisionAndTimeZone(as: try XCTUnwrap(due(hour: 12, minute: 30, zone: "Asia/Tokyo"))))
        let tomorrow = try XCTUnwrap(due(2026, 9, 6, hour: 12, minute: 30))
        XCTAssertTrue(floating.hasSamePrecisionAndTimeZone(as: tomorrow))
        XCTAssertLessThan(try XCTUnwrap(floating.chronologicalDate), try XCTUnwrap(tomorrow.chronologicalDate))
        let lordHoweFold = try XCTUnwrap(due(2026, 4, 5, hour: 1, minute: 45, zone: "Australia/Lord_Howe"))
        XCTAssertNil(lordHoweFold.chronologicalDate, "Non-hour DST folds are ambiguous too")
    }

    func testDerivedWeekFieldsDoNotChangeDueIdentity() throws {
        var base = DateComponents()
        base.year = 2026; base.month = 9; base.day = 5
        base.hour = 12; base.minute = 30
        base.timeZone = TimeZone(identifier: "Asia/Tokyo")
        var enriched = base
        enriched.weekOfYear = 36; enriched.yearForWeekOfYear = 2026
        enriched.weekday = 7; enriched.weekdayOrdinal = 1; enriched.weekOfMonth = 1
        XCTAssertEqual(try XCTUnwrap(ReminderDueValue(components: base)),
                       try XCTUnwrap(ReminderDueValue(components: enriched)))
        enriched.minute = nil
        XCTAssertNotEqual(ReminderDueValue(components: base), ReminderDueValue(components: enriched))
    }

    func testMissingAndInvalidDates() throws {
        XCTAssertNil(ReminderDueValue(components: nil))
        XCTAssertNil(ReminderDueValue(components: DateComponents()))
        XCTAssertNil(try XCTUnwrap(due(2026, 2, 30)).chronologicalDate)
        XCTAssertNil(try XCTUnwrap(due(hour: 25)).chronologicalDate)
        let invalidZoned = try XCTUnwrap(due(2026, 2, 30, hour: 12, zone: "Asia/Tokyo"))
        XCTAssertTrue(invalidZoned.dictionary["date_time"] is NSNull)
    }

    func testMetadataPreservesUnavailableRulesAndEmptyRules() {
        // Defensive-contract case, NOT a production-reachable state (#203):
        // `ReminderReadSnapshot(from:)` yields `rules == nil` only when
        // `hasRecurrenceRules` is false. Kept so the serializer's documented
        // `null` contract holds even if a future capture produces it.
        XCTAssertTrue(reminderMetadata(hasRecurrence: true, rules: nil, due: nil)["recurrence_rules"] is NSNull)
        let metadata = reminderMetadata(hasRecurrence: false, rules: nil, due: nil)
        XCTAssertEqual(metadata["has_recurrence"] as? Bool, false)
        XCTAssertEqual((metadata["recurrence_rules"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue(metadata["due"] is NSNull)
    }

    func testRecurringItemSerializesEveryRuleInOrder() {
        // The production-reachable recurring shape (#203): one entry per rule.
        // (The non-recurring snapshot carries `rules == nil` — EventKit's
        // `recurrenceRules` is nil, not empty — and the serializer emits a literal
        // `[]` without reading `rules`; that branch is pinned by
        // testMetadataPreservesUnavailableRulesAndEmptyRules.)
        let daily = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let yearly = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .yearly, interval: 3, end: nil))
        let metadata = reminderMetadata(hasRecurrence: true, rules: [daily, yearly], due: nil)
        let rules = metadata["recurrence_rules"] as? [[String: Any]]
        XCTAssertEqual(rules?.map { $0["frequency"] as? String }, ["daily", "yearly"])
        XCTAssertEqual(rules?.map { $0["interval"] as? Int }, [1, 3])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(metadata))
    }

    func testRuleDictionaryEmitsFrequencyRawValue() {
        // docs/REMINDER_RECURRENCE.md promises this field as the escape hatch for a
        // future frequency that serializes as "unknown"; it must actually be on the wire.
        let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        let json = ReminderRecurrenceRuleValue(from: rule).dictionary
        XCTAssertEqual(json["frequency"] as? String, "weekly")
        XCTAssertEqual(json["frequency_raw_value"] as? Int, EKRecurrenceFrequency.weekly.rawValue)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testRecurringItemWithEmptyRulesReportsNullRulesNotEmptyArray() {
        // Docs: `[]` means non-recurring, `null` means recurring with unavailable rules.
        // A recurring item whose rules array is empty must not look non-recurring.
        XCTAssertTrue(reminderMetadata(hasRecurrence: true, rules: [], due: nil)["recurrence_rules"] is NSNull)
        XCTAssertEqual((reminderMetadata(hasRecurrence: false, rules: [], due: nil)["recurrence_rules"] as? [Any])?.count, 0)
    }

    func testSubSecondDueRendersMillisecondsOnBothTimeAndDateTime() throws {
        // `time` used to carry 9-digit nanoseconds while `date_time` dropped them:
        // the two representations of one due disagreed in precision (row 8).
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 5; c.hour = 12; c.minute = 30; c.second = 5
        c.nanosecond = 250_000_000
        c.timeZone = TimeZone(secondsFromGMT: 0)
        let json = try XCTUnwrap(ReminderDueValue(components: c)).dictionary
        XCTAssertEqual(json["time"] as? String, "12:30:05.250")
        XCTAssertEqual(json["date_time"] as? String, "2026-09-05T12:30:05.250Z")
    }
}
