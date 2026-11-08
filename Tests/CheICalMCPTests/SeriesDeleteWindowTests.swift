import EventKit
import XCTest
@testable import CheICalMCP

/// #319: the window a whole-series delete lists the series' exceptions over
/// (`SeriesExceptionsPlanner.deleteWindow`). Before #319 it was the create-undo scan window
/// (`UndoPostState.seriesScanWindow`), anchored at the series' first occurrence, so for a series
/// that began more than about four years before the delete it lay entirely in the past.
/// PR #494 round 1: it looks back three years (1094 days), so it is the old window for every series
/// begun within about three years of the delete, and a count rule's end is its last possible slot,
/// not "open-ended".
final class SeriesDeleteWindowTests: XCTestCase {
    private let day: TimeInterval = 86_400
    /// The time of the delete.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * day) }
    private func window(first: Double, _ end: SeriesExceptionsPlanner.SeriesEnd) -> SeriesExceptionsPlanner.DeleteWindow {
        SeriesExceptionsPlanner.deleteWindow(firstStart: days(first), end: end, deletedAt: now)
    }

    // MARK: - placement

    /// A series that began a few days ago gets the window it had before #319: from one day before
    /// its first occurrence, 1460 days long.
    func testANewSeriesKeepsTheWindowFromItsFirstOccurrence() {
        let result = window(first: -10, .open)

        XCTAssertEqual(result.window, UndoPostState.seriesScanWindow(firstStart: days(-10), ruleEnd: nil))
        XCTAssertFalse(result.seriesStartsBefore)
        XCTAssertTrue(result.seriesContinuesAfter, "open-ended: the series goes on past four years")
    }

    /// Round 1 (regression): a series begun two years before the delete, with an exception in its
    /// first month, still gets the old window, so that exception is restored. A one-year look-back
    /// left it out.
    func testASeriesBegunTwoYearsBeforeTheDeleteKeepsTheOldWindow() {
        let result = window(first: -730, .open)

        XCTAssertEqual(result.window, UndoPostState.seriesScanWindow(firstStart: days(-730), ruleEnd: nil))
        XCTAssertTrue(result.window.contains(days(-720)), "an exception in its first month")
        XCTAssertFalse(result.seriesStartsBefore)
    }

    /// The case of the issue: an open-ended series begun ten years ago. The window starts three
    /// years before the delete and is 1460 days long, so it holds the delete and a year after it.
    func testAnOldOpenEndedSeriesIsListedAroundTheDelete() {
        let result = window(first: -3650, .open)

        XCTAssertEqual(result.window.start, days(-1094))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.window.contains(now))
        XCTAssertTrue(result.window.contains(days(365)), "an exception a year after the delete is kept")
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertTrue(result.seriesContinuesAfter)
    }

    /// An old series whose rule ended two years before the delete: the window is its last four
    /// years, ending one day after the rule's end, not a window after the series ended.
    func testAnOldSeriesThatEndedBeforeTheDeleteIsListedOverItsLastFourYears() {
        let ruleEnd = days(-730)
        let result = window(first: -3650, .endsAt(ruleEnd))

        XCTAssertEqual(result.window.end, ruleEnd.addingTimeInterval(day))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
        XCTAssertFalse(result.seriesMayContinueAfter)
    }

    /// An old series ending soon after the delete: the window starts four years before the end of
    /// the rule (earlier than three years before the delete), so it still reaches that end.
    func testAnOldSeriesEndingSoonIsListedUpToItsEnd() {
        let ruleEnd = days(100)
        let result = window(first: -3650, .endsAt(ruleEnd))

        XCTAssertEqual(result.window.end, ruleEnd.addingTimeInterval(day))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.window.contains(now))
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
    }

    /// An old series ending long after the delete: three years before the delete, 1460 days, and
    /// the rest of the rule lies after the window.
    func testAnOldSeriesEndingLateIsListedFromThreeYearsBeforeTheDelete() {
        let result = window(first: -3650, .endsAt(days(2000)))

        XCTAssertEqual(result.window.start, days(-1094))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertTrue(result.seriesContinuesAfter)
    }

    /// A short series that begins and ends inside the window is listed whole.
    func testAShortSeriesIsListedWhole() {
        let result = window(first: -30, .endsAt(days(30)))

        XCTAssertEqual(result.window, DateInterval(start: days(-31), end: days(31)))
        XCTAssertFalse(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
        XCTAssertFalse(result.seriesMayContinueAfter)
    }

    /// A series that begins after the delete (a future series) starts its window at its first
    /// occurrence, as before.
    func testAFutureSeriesStartsAtItsFirstOccurrence() {
        let result = window(first: 400, .open)

        XCTAssertEqual(result.window.start, days(399))
        XCTAssertFalse(result.seriesStartsBefore)
    }

    /// Round 1 (LOW): "occurrences before the window" means before the first occurrence, not
    /// before one day ahead of it. A window starting between the two leaves none out.
    func testAWindowStartingBetweenTheDayBeforeAndTheFirstOccurrenceLeavesNoneBefore() {
        let result = window(first: -1093.5, .open)

        XCTAssertEqual(result.window.start, days(-1094))
        XCTAssertFalse(result.seriesStartsBefore)
    }

    // MARK: - count rules (round 1, MEDIUM 1 + 2)

    /// A weekly series of 10 that ended years before the delete: the window reaches its end, so it
    /// holds every occurrence. Placed as open-ended, it lay after the series and held none, so the
    /// capture was nil and the undo restored the series from its rules alone.
    func testACountSeriesThatEndedLongAgoIsListedWhole() {
        let first = days(-3000)
        let lastPossible = first.addingTimeInterval(70 * day)
        let result = window(first: -3000, .endsBy(lastPossible))

        XCTAssertEqual(result.window.start, first.addingTimeInterval(-day))
        XCTAssertEqual(result.window.end, lastPossible.addingTimeInterval(day))
        XCTAssertFalse(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
        XCTAssertFalse(result.seriesMayContinueAfter)
    }

    /// A weekly series of 10 begun ten days ago lies inside its window: it is not said to have
    /// occurrences after it.
    func testACountSeriesInsideTheWindowHasNoneAfterIt() {
        let result = window(first: -10, .endsBy(days(60)))

        XCTAssertEqual(result.window.end, days(61))
        XCTAssertFalse(result.seriesContinuesAfter)
        XCTAssertFalse(result.seriesMayContinueAfter)
    }

    /// A count whose end cannot be shown is placed as open-ended, and the series may have
    /// occurrences after the window (not "has").
    func testAFilteredCountWhoseEndCannotBeShownMayContinueAfterTheWindow() {
        let result = window(first: -3650, .unknown)

        XCTAssertEqual(result.window.start, days(-1094))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertFalse(result.seriesContinuesAfter)
        XCTAssertTrue(result.seriesMayContinueAfter)
    }

    /// A count bound past the window is an upper bound: the series may continue after it.
    func testACountBoundPastTheWindowMayContinueAfterIt() {
        let result = window(first: -3650, .endsBy(days(2000)))

        XCTAssertFalse(result.seriesContinuesAfter)
        XCTAssertTrue(result.seriesMayContinueAfter)
    }

    /// Every window fits one EventKit query (at most 1460 days), whatever the series.
    func testNoWindowIsLongerThanOneQuery() {
        for first in [-5000.0, -1500, -1094, -366, -1, 0, 30, 1500] {
            let ends: [SeriesExceptionsPlanner.SeriesEnd] = [.open, .unknown]
                + [-2000.0, -400, 0, 10, 900, 5000].flatMap { [SeriesExceptionsPlanner.SeriesEnd.endsAt(days($0)), .endsBy(days($0))] }
            for end in ends {
                let result = window(first: first, end)
                XCTAssertLessThanOrEqual(result.window.duration, 1460 * day, "first \(first), end \(end)")
                XCTAssertGreaterThanOrEqual(result.window.duration, 0)
            }
        }
    }

    /// #319 keeps the create-undo scan window as it was (#259, and the stand-in scan use it).
    func testTheCreateUndoScanWindowIsUnchanged() {
        let window = UndoPostState.seriesScanWindow(firstStart: days(-3650), ruleEnd: nil)
        XCTAssertEqual(window.start, days(-3651))
        XCTAssertEqual(window.duration, 1460 * day)
    }

    // MARK: - seriesEnd from the rules

    private let calendar = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)
    private func extent(_ frequency: EKRecurrenceFrequency, end: EKRecurrenceEnd?, daysOfTheMonth: [NSNumber]? = nil) -> DetachedOccurrenceSpan.RuleExtent {
        DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: frequency, interval: 1, daysOfTheWeek: nil,
                                                           daysOfTheMonth: daysOfTheMonth, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                                           daysOfTheYear: nil, setPositions: nil, end: end))
    }

    func testAnOpenRuleIsOpen() {
        XCTAssertEqual(SeriesExceptionsPlanner.seriesEnd(rules: [extent(.weekly, end: nil)], firstStart: now, calendar: calendar), .open)
    }

    func testAnEndDateRuleEndsAtItsDate() {
        XCTAssertEqual(SeriesExceptionsPlanner.seriesEnd(rules: [extent(.weekly, end: EKRecurrenceEnd(end: days(90)))], firstStart: now, calendar: calendar),
                       .endsAt(days(90)))
    }

    /// A weekly count of 10 reaches at most 70 days past its first occurrence (`lastPossibleSlot`).
    func testACountRuleEndsByItsLastPossibleSlot() {
        XCTAssertEqual(SeriesExceptionsPlanner.seriesEnd(rules: [extent(.weekly, end: EKRecurrenceEnd(occurrenceCount: 10))], firstStart: now, calendar: calendar),
                       .endsBy(days(70)))
    }

    func testAFilteredCountRuleIsUnknown() {
        let filtered = extent(.monthly, end: EKRecurrenceEnd(occurrenceCount: 10), daysOfTheMonth: [31])
        XCTAssertEqual(SeriesExceptionsPlanner.seriesEnd(rules: [filtered], firstStart: now, calendar: calendar), .unknown)
    }

    /// Several rules: open wins, then unknown, then a count's bound, then end dates.
    func testSeveralRulesTakeTheWidestEnd() {
        let open = extent(.weekly, end: nil)
        let dated = extent(.weekly, end: EKRecurrenceEnd(end: days(400)))
        let counted = extent(.weekly, end: EKRecurrenceEnd(occurrenceCount: 10))
        let filtered = extent(.monthly, end: EKRecurrenceEnd(occurrenceCount: 10), daysOfTheMonth: [31])
        func end(_ rules: [DetachedOccurrenceSpan.RuleExtent]) -> SeriesExceptionsPlanner.SeriesEnd {
            SeriesExceptionsPlanner.seriesEnd(rules: rules, firstStart: now, calendar: calendar)
        }
        XCTAssertEqual(end([dated, open]), .open)
        XCTAssertEqual(end([dated, filtered]), .unknown)
        XCTAssertEqual(end([dated, counted]), .endsBy(days(400)), "the later of the two, an upper bound")
        XCTAssertEqual(end([counted, dated]), .endsBy(days(400)))
        XCTAssertEqual(end([dated, extent(.weekly, end: EKRecurrenceEnd(end: days(500)))]), .endsAt(days(500)))
    }
}
