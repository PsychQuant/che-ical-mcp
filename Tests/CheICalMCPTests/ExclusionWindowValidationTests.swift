import XCTest
@testable import CheICalMCP

/// Pure-unit tests for `EventKitManager.validateExclusionWindow` (#182 verify
/// round-1 fixes, findings #5/#6). Static + EventKit-free — runs on CI.
final class ExclusionWindowValidationTests: XCTestCase {

    private let tz = TimeZone(identifier: "America/Toronto")!

    /// #306: `en_US_POSIX`, as the production parser (`FlexibleDate.formatter`) sets it; without
    /// it a Buddhist host read 2026 as a Buddhist year. No explicit calendar, so an impossible
    /// date still fails to parse instead of rolling over (#299).
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = tz
        return f.date(from: s)!
    }

    private func rule(endDate: Date? = nil, count: Int? = nil, frequency: RecurrenceRuleInput.Frequency = .daily, interval: Int = 1) -> RecurrenceRuleInput {
        RecurrenceRuleInput(frequency: frequency, interval: interval, endDate: endDate,
                            occurrenceCount: count, daysOfWeek: nil, daysOfMonth: nil,
                            excludedOccurrenceDates: nil)
    }

    /// Finding #5 — excluding the first occurrence day is rejected.
    func testFirstOccurrenceExclusionRejected() {
        XCTAssertThrowsError(try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-09-01T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(endDate: date("2026-09-30T00:00:00")),
            timezone: tz
        )) { error in
            guard case EventKitError.exclusionFirstOccurrence = error else {
                return XCTFail("expected .exclusionFirstOccurrence, got \(error)")
            }
        }
    }

    /// Finding #6 — exclusion count >= occurrence_count empties the series.
    /// Monthly: no count-derived day bound applies (R2 — no cheap loose bound),
    /// so both dates pass the window pass and the removes-all check is reachable.
    func testExclusionSetCoveringWholeSeriesRejected() {
        XCTAssertThrowsError(try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-10-01T00:00:00"), date("2026-11-01T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(count: 2, frequency: .monthly),
            timezone: tz
        )) { error in
            guard case EventKitError.exclusionRemovesAllOccurrences(let e, let c) = error else {
                return XCTFail("expected .exclusionRemovesAllOccurrences, got \(error)")
            }
            XCTAssertEqual(e, 2); XCTAssertEqual(c, 2)
        }
    }

    /// R2 ordering — an out-of-window date is reported as out-of-window, never as
    /// removes-all (daily count bound: window pass rejects before the count check).
    func testOutOfWindowWinsOverRemovesAll() {
        XCTAssertThrowsError(try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-09-02T00:00:00"), date("2026-09-03T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(count: 2),
            timezone: tz
        )) { error in
            guard case EventKitError.exclusionOutOfWindow(let d) = error else {
                return XCTFail("expected .exclusionOutOfWindow, got \(error)")
            }
            XCTAssertEqual(d, "2026-09-03")
        }
    }

    /// R2 — monthly gets NO count-derived bound (days_of_month can skip months), so a
    /// far-future date within no end_date passes the window pass.
    func testMonthlyCountImposesNoDayBound() throws {
        try EventKitManager.validateExclusionWindow(
            excluded: [date("2027-01-31T00:00:00")],
            startDate: date("2026-01-31T09:00:00"),
            rule: rule(count: 5, frequency: .monthly),
            timezone: tz
        )
    }

    /// Finding #6 — a date past the occurrence_count-derived bound is rejected pre-save.
    func testDateBeyondCountWindowRejected() {
        // daily count=5 starting 2026-09-01 → last possible day 2026-09-05
        XCTAssertThrowsError(try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-09-20T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(count: 5),
            timezone: tz
        )) { error in
            guard case EventKitError.exclusionOutOfWindow = error else {
                return XCTFail("expected .exclusionOutOfWindow, got \(error)")
            }
        }
    }

    /// Weekly count bound is deliberately loose (interval*7): in-bound passes.
    func testWeeklyCountWindowLooseBoundAccepts() throws {
        // weekly count=4 from 2026-09-01 → bound = start + 21d = 2026-09-22
        try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-09-15T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(count: 4, frequency: .weekly),
            timezone: tz
        )
    }

    /// end_date bound still enforced (pre-fix behavior retained).
    func testDateAfterEndDateRejected() {
        XCTAssertThrowsError(try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-10-15T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(endDate: date("2026-09-30T00:00:00")),
            timezone: tz
        )) { error in
            guard case EventKitError.exclusionOutOfWindow = error else {
                return XCTFail("expected .exclusionOutOfWindow, got \(error)")
            }
        }
    }

    /// Valid mid-series exclusion passes all gates.
    func testValidMidSeriesExclusionAccepted() throws {
        try EventKitManager.validateExclusionWindow(
            excluded: [date("2026-09-07T00:00:00"), date("2026-09-14T00:00:00")],
            startDate: date("2026-09-01T09:00:00"),
            rule: rule(endDate: date("2026-09-30T00:00:00")),
            timezone: tz
        )
    }
}
