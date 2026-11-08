import XCTest
@testable import CheICalMCP

/// PR #494 round 4: a record can hold more than one window (`SeriesExceptions.extraWindows`). A
/// count whose end cannot be shown records the window around the delete and the window from its
/// first occurrence; every judgment (captured, surplus, first slot) holds inside either.
final class SeriesExceptionsWindowsTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func d(_ n: Double) -> Date { base.addingTimeInterval(n * day) }
    private let series = UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "X-S")

    private func observed(_ slot: Date) -> SeriesExceptionsPlanner.ObservedOccurrence {
        .init(ids: series, isDetached: false, occurrenceDate: slot, startDate: slot,
              snapshot: UndoSnapshotFixtures.event(title: "Standup", startDate: slot))
    }

    private var a: DateInterval { DateInterval(start: d(0), end: d(10)) }
    private var b: DateInterval { DateInterval(start: d(100), end: d(110)) }

    func testACaptureOverTwoWindowsKeepsTheSlotsInEither() throws {
        let exceptions = try XCTUnwrap(SeriesExceptionsPlanner.capture([d(1), d(50), d(101)].map(observed), of: series, windows: [a, b]))
        XCTAssertEqual(exceptions.keptSlots, [d(1), d(101)])
        XCTAssertEqual(exceptions.windows, [a, b])
    }

    func testACaptureWithAnOccurrenceOnlyInTheSecondWindowIsNotNil() throws {
        let exceptions = try XCTUnwrap(SeriesExceptionsPlanner.capture([d(105)].map(observed), of: series, windows: [a, b]))
        XCTAssertEqual(exceptions.keptSlots, [d(105)])
    }

    func testSurplusSlotsComeFromEitherWindowAndNotBetween() {
        let exceptions = SeriesExceptions(window: a, keptSlots: [d(1)], detached: [], extraWindows: [b])
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(generated: [d(1), d(2), d(50), d(102)], exceptions: exceptions), [d(2), d(102)])
    }

    /// The first slot is required when it is inside either window.
    func testTheRestorerRequiresAFirstSlotInsideTheExtraWindow() throws {
        let exceptions = SeriesExceptions(window: b, keptSlots: [d(101)], detached: [], extraWindows: [a])
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: exceptions, seriesStart: d(1), generated: [(d(101), d(101)), (d(102), d(102))],
            remove: { _ in XCTFail("nothing is removed") }, createOneOff: { $0.slot }, removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertTrue(outcome.notApplied)
    }

    func testTheRestorerRemovesSurplusInsideEitherWindow() throws {
        let exceptions = SeriesExceptions(window: b, keptSlots: [d(1), d(101)], detached: [], extraWindows: [a])
        var removed: [Date] = []
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: exceptions, seriesStart: d(1), generated: [d(1), d(2), d(101), d(102)].map { ($0, $0) },
            remove: { removed.append($0) }, createOneOff: { $0.slot }, removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertEqual(outcome, .init(stayedDeleted: 2, oneOffs: 0))
        XCTAssertEqual(removed.sorted(), [d(2), d(102)])
    }

    // MARK: - PR #494 round 6: one listing for two windows

    /// The listing ranges of two windows that overlap: disjoint, each at most one EventKit query
    /// (1460 days), and together covering every listing range of either window.
    func testTheListingRangesOfTwoWindowsAreDisjointAndBounded() {
        let around = DateInterval(start: d(-1094), duration: 1460 * day)
        let fromFirst = DateInterval(start: d(-1501), duration: 1460 * day)
        let ranges = SeriesExceptionsPlanner.listingRanges(covering: [around, fromFirst])
        for range in ranges { XCTAssertLessThanOrEqual(range.duration, 1460 * day) }
        for (a, b) in zip(ranges, ranges.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start, "disjoint, in order") }
        let needed = [around, fromFirst].flatMap(SeriesExceptionsPlanner.listingRanges(for:))
        let start = needed.map(\.start).min()!, end = needed.map(\.end).max()!
        XCTAssertEqual(ranges.first?.start, start)
        XCTAssertEqual(ranges.last?.end, end)
        XCTAssertEqual(ranges.map(\.duration).reduce(0, +), end.timeIntervalSince(start), accuracy: 1, "no gap and no overlap")
        XCTAssertLessThan(ranges.count, 6, "fewer queries than listing each window's three ranges")
    }

    /// Two windows far apart: each keeps its own ranges (no query over the gap between them).
    func testTheListingRangesOfTwoDistantWindowsLeaveTheGapOut() {
        let late = DateInterval(start: d(5000), duration: 1460 * day)
        let early = DateInterval(start: d(0), duration: 1460 * day)
        let ranges = SeriesExceptionsPlanner.listingRanges(covering: [late, early])
        let gap = DateInterval(start: d(1460 + 366), end: d(5000 - 366))
        XCTAssertFalse(ranges.contains { $0.intersects(gap) && $0.intersection(with: gap)!.duration > 0 })
        for range in ranges { XCTAssertLessThanOrEqual(range.duration, 1460 * day) }
    }
}
