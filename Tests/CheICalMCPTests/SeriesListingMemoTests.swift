import EventKit
import XCTest
@testable import CheICalMCP

/// #527: `update_event` listed a series twice, once for the baseline of the deleted-occurrence check
/// and once for its verdict. `SeriesListingMemo` makes a listing once per key (the calendar, the
/// series and the resolved ranges) inside a stretch of checks and every time outside one. The
/// listing itself is a closure here (the seam `EventKitManager.seriesOccurrences` reads through), so
/// each test counts how often a listing was requested.
final class SeriesListingMemoTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 820_000_000)

    /// The base ranges of a series begun at `start`: its scan window and a year on each side.
    private var base: [DateInterval] {
        SeriesExceptionsPlanner.listingRanges(for: UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: nil))
    }

    private func key(calendar: String = "C", id: String = "S", external: String? = "X-S", ranges: [DateInterval]? = nil) -> SeriesListingKey {
        SeriesListingKey(calendarIdentifier: calendar, eventIdentifier: id, externalIdentifier: external, ranges: ranges ?? base)
    }

    /// A listing that counts its requests per key and answers with the request's number.
    private final class Lister {
        var requests: [SeriesListingKey: Int] = [:]
        var total = 0
        func list(_ key: SeriesListingKey) -> Int {
            requests[key, default: 0] += 1
            total += 1
            return total
        }
    }

    // MARK: - Inside a stretch

    /// The shape of `update_event` on a series begun this week: the baseline lists the base ranges,
    /// then the verdict asks for the same ranges and reads the baseline's listing.
    func testTheBaselineAndTheVerdictOverTheSameRangesListOnce() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        let (baseline, verdict) = memo.sharing {
            (memo.listing(for: key()) { lister.list(key()) }, memo.listing(for: key()) { lister.list(key()) })
        }
        XCTAssertEqual(lister.total, 1, "one listing for the two readers")
        XCTAssertEqual(baseline, 1)
        XCTAssertEqual(verdict, 1, "the verdict reads the listing the baseline made")
        XCTAssertEqual(lister.requests[key()], 1)
    }

    /// The shape on an open-ended series begun years ago: the verdict lists the window around now
    /// as well (#506), which is another set of ranges, so both are listed, once each.
    func testOtherRangesAreListedToo() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        let window = UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: nil)
        let now = start.addingTimeInterval(8 * 365 * day)
        let around = SeriesExceptionsPlanner.listingRanges(covering: [
            window, DeletedOccurrenceCheck.windowAroundNow(now: now, horizon: now.addingTimeInterval(731 * day))])
        XCTAssertNotEqual(around, base)
        memo.sharing {
            _ = memo.listing(for: key()) { lister.list(key()) }
            _ = memo.listing(for: key(ranges: around)) { lister.list(key(ranges: around)) }
            _ = memo.listing(for: key(ranges: around)) { lister.list(key(ranges: around)) }
            _ = memo.listing(for: key()) { lister.list(key()) }
        }
        XCTAssertEqual(lister.total, 2, "once per set of ranges")
        XCTAssertEqual(lister.requests[key()], 1)
        XCTAssertEqual(lister.requests[key(ranges: around)], 1)
    }

    /// Everything the listing depends on is in the key: another calendar, another series (by either
    /// identifier), the same ranges in another order or cut elsewhere, each is its own listing.
    func testEveryPartOfTheKeyTellsListingsApart() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        let reordered = Array(base.reversed())
        let merged = [DateInterval(start: base.map(\.start).min()!, end: base.map(\.end).max()!)]
        let keys = [key(), key(calendar: "D"), key(id: "T"), key(external: "X-T"), key(external: nil),
                    key(ranges: reordered), key(ranges: merged), key(ranges: [])]
        XCTAssertEqual(Set(keys).count, keys.count)
        memo.sharing {
            for _ in 0..<3 {
                for each in keys { _ = memo.listing(for: each) { lister.list(each) } }
            }
        }
        XCTAssertEqual(lister.total, keys.count)
        for each in keys { XCTAssertEqual(lister.requests[each], 1, "\(each)") }
    }

    /// An empty listing is a listing: it is kept and not asked for again (a series whose ranges hold
    /// none of its occurrences answers the same to both readers).
    func testAnEmptyListingIsKeptToo() {
        let memo = SeriesListingMemo<[Int]>()
        var requests = 0
        memo.sharing {
            XCTAssertEqual(memo.listing(for: key()) { requests += 1; return [] }, [])
            XCTAssertEqual(memo.listing(for: key()) { requests += 1; return [1] }, [])
        }
        XCTAssertEqual(requests, 1)
    }

    // MARK: - Outside a stretch, and its end

    /// With no stretch open every call lists, as every caller but `update_event`'s check does.
    func testOutsideAStretchEveryCallLists() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        XCTAssertFalse(memo.isSharing)
        XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 1)
        XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 2)
        XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 3)
        XCTAssertEqual(lister.total, 3)
    }

    /// What a stretch kept is gone when it ends: the next call lists, and so does the next stretch.
    func testNothingIsKeptAfterAStretch() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        memo.sharing {
            XCTAssertTrue(memo.isSharing)
            _ = memo.listing(for: key()) { lister.list(key()) }
        }
        XCTAssertFalse(memo.isSharing)
        XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 2, "listed again after the stretch")
        memo.sharing {
            XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 3, "a new stretch starts with nothing kept")
            XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 3)
        }
        XCTAssertEqual(lister.total, 3)
    }

    private struct Refused: Error {}

    /// A refusal thrown inside the stretch ends it: nothing stays kept for the next call.
    func testAThrowEndsTheStretch() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        XCTAssertThrowsError(try memo.sharing {
            _ = memo.listing(for: self.key()) { lister.list(self.key()) }
            throw Refused()
        })
        XCTAssertFalse(memo.isSharing)
        XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 2)
        XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 3)
    }

    /// A stretch opened inside another one is part of it: the inner end does not end the sharing,
    /// and the outer one keeps what the inner one listed.
    func testAStretchInsideAnotherIsPartOfIt() {
        let memo = SeriesListingMemo<Int>()
        let lister = Lister()
        memo.sharing {
            _ = memo.listing(for: key()) { lister.list(key()) }
            memo.sharing {
                XCTAssertEqual(memo.listing(for: key()) { lister.list(key()) }, 1)
                _ = memo.listing(for: key(id: "T")) { lister.list(key(id: "T")) }
            }
            XCTAssertTrue(memo.isSharing, "the inner stretch did not end the outer one")
            XCTAssertEqual(memo.listing(for: key(id: "T")) { lister.list(key(id: "T")) }, 2)
        }
        XCTAssertFalse(memo.isSharing)
        XCTAssertEqual(lister.total, 2)
    }

    /// `sharing` hands back what the checks returned.
    func testSharingReturnsTheChecksValue() {
        let memo = SeriesListingMemo<Int>()
        XCTAssertEqual(memo.sharing { 7 }, 7)
    }

    // MARK: - When the ranges coincide

    /// The verdict's ranges (`DeletedOccurrenceCheck.listingRanges`) equal the baseline's base
    /// ranges, so the keys are equal and one listing serves both, when no horizon is passed, when
    /// the base ranges reach the horizon (a series begun less than about three years ago), and when
    /// they cover the series. For an open-ended series begun longer ago they differ, and both are listed.
    func testTheVerdictsRangesAreTheBaselinesExceptAroundNow() {
        let calendar = Calendar.gregorian(in: TimeZone(identifier: "Asia/Taipei")!)
        let open = [DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))]
        func ranges(start: Date, now: Date, horizon: Bool, rules: [DetachedOccurrenceSpan.RuleExtent]) -> [DateInterval] {
            let window = UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: rules.compactMap(\.endDate).max())
            return DeletedOccurrenceCheck.listingRanges(
                window: window, horizon: horizon ? DeletedOccurrenceCheck.horizon(now: now, calendar: calendar) : nil, now: now,
                rules: rules, firstStart: start, calendar: calendar)
        }
        func baseRanges(start: Date, rules: [DetachedOccurrenceSpan.RuleExtent]) -> [DateInterval] {
            SeriesExceptionsPlanner.listingRanges(for: UndoPostState.seriesScanWindow(firstStart: start, ruleEnd: rules.compactMap(\.endDate).max()))
        }
        let now = start.addingTimeInterval(3_000 * day)
        // Begun three days ago, open-ended, with a horizon: the base ranges end after it.
        let recent = now.addingTimeInterval(-3 * day)
        XCTAssertEqual(ranges(start: recent, now: now, horizon: true, rules: open), baseRanges(start: recent, rules: open))
        // Begun 1,000 days ago: still inside (1,825 days of base ranges against a horizon 731 days out).
        let twoYears = now.addingTimeInterval(-1_000 * day)
        XCTAssertEqual(ranges(start: twoYears, now: now, horizon: true, rules: open), baseRanges(start: twoYears, rules: open))
        // Begun eight years ago, open-ended, with a horizon: the window around now is listed too.
        XCTAssertNotEqual(ranges(start: start, now: now, horizon: true, rules: open), baseRanges(start: start, rules: open))
        // The same series with no horizon (another account, a new pattern, an all-day change).
        XCTAssertEqual(ranges(start: start, now: now, horizon: false, rules: open), baseRanges(start: start, rules: open))
        // Begun eight years ago and ended after 30 days: the base ranges cover it.
        let ended = [DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
                                                                        end: EKRecurrenceEnd(end: start.addingTimeInterval(30 * day))))]
        XCTAssertEqual(ranges(start: start, now: now, horizon: true, rules: ended), baseRanges(start: start, rules: ended))
    }
}
