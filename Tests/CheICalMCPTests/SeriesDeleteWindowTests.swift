import XCTest
@testable import CheICalMCP

/// #319: the window a whole-series delete lists the series' exceptions over
/// (`SeriesExceptionsPlanner.deleteWindow`). Before #319 it was the create-undo scan window
/// (`UndoPostState.seriesScanWindow`), anchored at the series' first occurrence, so for a series
/// that began more than about four years before the delete it lay entirely in the past.
final class SeriesDeleteWindowTests: XCTestCase {
    private let day: TimeInterval = 86_400
    /// The time of the delete.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * day) }

    /// A series that began a few days ago gets the window it had before #319: from one day before
    /// its first occurrence, 1460 days long.
    func testANewSeriesKeepsTheWindowFromItsFirstOccurrence() {
        let first = days(-10)
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: first, ruleEnd: nil, deletedAt: now)

        XCTAssertEqual(result.window, UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: nil))
        XCTAssertFalse(result.seriesStartsBefore)
        XCTAssertTrue(result.seriesContinuesAfter, "open-ended: the series goes on past four years")
    }

    /// The case of the issue: an open-ended series begun ten years ago. The window starts a year
    /// before the delete and is 1460 days long, so the occurrences around the delete are listed.
    func testAnOldOpenEndedSeriesIsListedAroundTheDelete() {
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: days(-3650), ruleEnd: nil, deletedAt: now)

        XCTAssertEqual(result.window.start, days(-366))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.window.contains(now))
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertTrue(result.seriesContinuesAfter)
    }

    /// An old series whose rule ended two years before the delete: the window is its last four
    /// years, ending one day after the rule's end, not a window after the series ended.
    func testAnOldSeriesThatEndedBeforeTheDeleteIsListedOverItsLastFourYears() {
        let ruleEnd = days(-730)
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: days(-3650), ruleEnd: ruleEnd, deletedAt: now)

        XCTAssertEqual(result.window.end, ruleEnd.addingTimeInterval(day))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
    }

    /// An old series ending within three years of the delete: the window starts four years before
    /// the end of the rule (earlier than a year before the delete), so it still reaches that end.
    func testAnOldSeriesEndingSoonIsListedUpToItsEnd() {
        let ruleEnd = days(100)
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: days(-3650), ruleEnd: ruleEnd, deletedAt: now)

        XCTAssertEqual(result.window.end, ruleEnd.addingTimeInterval(day))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.window.contains(now))
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
    }

    /// An old series ending more than three years after the delete: a year before the delete,
    /// 1460 days, and the rest of the rule lies after the window.
    func testAnOldSeriesEndingLateIsListedFromAYearBeforeTheDelete() {
        let ruleEnd = days(2000)
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: days(-3650), ruleEnd: ruleEnd, deletedAt: now)

        XCTAssertEqual(result.window.start, days(-366))
        XCTAssertEqual(result.window.duration, 1460 * day)
        XCTAssertTrue(result.seriesStartsBefore)
        XCTAssertTrue(result.seriesContinuesAfter)
    }

    /// A short series that begins and ends inside the window is listed whole.
    func testAShortSeriesIsListedWhole() {
        let first = days(-30)
        let ruleEnd = days(30)
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: first, ruleEnd: ruleEnd, deletedAt: now)

        XCTAssertEqual(result.window, DateInterval(start: first.addingTimeInterval(-day), end: ruleEnd.addingTimeInterval(day)))
        XCTAssertFalse(result.seriesStartsBefore)
        XCTAssertFalse(result.seriesContinuesAfter)
    }

    /// A series that begins after the delete (a future series) starts its window at its first
    /// occurrence, as before.
    func testAFutureSeriesStartsAtItsFirstOccurrence() {
        let first = days(400)
        let result = SeriesExceptionsPlanner.deleteWindow(firstStart: first, ruleEnd: nil, deletedAt: now)

        XCTAssertEqual(result.window.start, first.addingTimeInterval(-day))
        XCTAssertFalse(result.seriesStartsBefore)
    }

    /// Every window fits one EventKit query (at most 1460 days), whatever the series.
    func testNoWindowIsLongerThanOneQuery() {
        for first in [-5000.0, -1500, -366, -1, 0, 30, 1500] {
            for end in [nil, -2000.0, -400, 0, 10, 900, 5000] as [Double?] {
                let result = SeriesExceptionsPlanner.deleteWindow(firstStart: days(first), ruleEnd: end.map(days), deletedAt: now)
                XCTAssertLessThanOrEqual(result.window.duration, 1460 * day, "first \(first), end \(String(describing: end))")
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
}
