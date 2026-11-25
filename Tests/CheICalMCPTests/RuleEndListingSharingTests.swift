import XCTest
@testable import CheICalMCP

/// #533: the #509 first-slot read and the #503 baseline ask `seriesOccurrences` for the same listing on
/// one route (span `all` through the series' id), and #527's stretch opened after the #509 read, so the
/// series was listed twice. A model test of the call orders, not of `updateEvent` itself (its readers run
/// only against an event store): the readers' requests run through the real `SeriesListingMemo` with a
/// fake store, in `main`'s order (the #509 read before the stretch) and in the branch's (the stretch
/// opened before it). With a store whose listing depends on the key only, each reader gets the same
/// listing in both orders, which holds by construction; what the model shows is the count (one listing
/// fewer exactly where two readers ask for one key) and, with a store whose listing changes on every
/// call, that the answers differ exactly in those shapes (the trade: one listing for both readers) and
/// that nothing is kept past a stretch. Where the readers sit in `updateEvent` is pinned in
/// `SingleListingWiringTests`.
final class RuleEndListingSharingTests: XCTestCase {
    private struct Shape: CustomStringConvertible {
        let throughSeriesID: Bool       // #509 reads the first slot only through the series' id (`wholeThroughSeries`)
        let ruleEndChecked: Bool        // `needsFirstSlot`: an end checked, or #513's month-end shape
        let baselineRuns: Bool          // #503: a whole-series write with dates
        let verdictRuns: Bool           // the check applies
        let verdictOwnWindow: Bool      // #506: a horizon the base ranges end before
        var description: String {
            "seriesID \(throughSeriesID) end \(ruleEndChecked) baseline \(baselineRuns) verdict \(verdictRuns) ownWindow \(verdictOwnWindow)"
        }
    }

    /// A store that lists a key's events: the listing depends on the key only, and each call is counted.
    private final class CountingStore {
        private(set) var calls: [SeriesListingKey] = []
        func list(_ key: SeriesListingKey) -> [String] {
            calls.append(key)
            return key.ranges.map { "\(key.eventIdentifier)@\($0.start.timeIntervalSinceReferenceDate)" }
        }
    }

    private let base = SeriesListingKey(calendarIdentifier: "C", eventIdentifier: "S", externalIdentifier: "U",
                                        ranges: [DateInterval(start: Date(timeIntervalSinceReferenceDate: 0), duration: 86_400 * 1460)])
    private var horizon: SeriesListingKey {
        SeriesListingKey(calendarIdentifier: "C", eventIdentifier: "S", externalIdentifier: "U",
                         ranges: base.ranges + [DateInterval(start: Date(timeIntervalSinceReferenceDate: 86_400 * 2000), duration: 86_400 * 730)])
    }

    /// A store that another process writes to between any two listings: every call gives another listing.
    private final class ChangingStore {
        private(set) var calls = 0
        func list(_ key: SeriesListingKey) -> [String] {
            calls += 1
            return ["\(key.eventIdentifier) generation \(calls)"]
        }
    }

    /// The readers in `updateEvent`'s order; `openBefore509` is where the stretch opens. `changing` uses a
    /// store whose listing changes on every call; `memo` lets a test pass one memo to several runs.
    private func run(_ shape: Shape, openBefore509: Bool, changing: Bool = false,
                     memo: SeriesListingMemo<[String]> = SeriesListingMemo<[String]>()) -> (answers: [String: [String]], listings: Int) {
        let store = CountingStore()
        let changingStore = ChangingStore()
        func list(_ key: SeriesListingKey) -> [String] { changing ? changingStore.list(key) : store.list(key) }
        var answers: [String: [String]] = [:]
        func ruleEnd() {
            if shape.throughSeriesID && shape.ruleEndChecked {
                answers["509"] = memo.listing(for: base) { list(base) }
            }
        }
        func stretch() {
            if shape.baselineRuns { answers["503 baseline"] = memo.listing(for: base) { list(base) } }
            if shape.verdictRuns {
                let key = shape.verdictOwnWindow ? horizon : base
                answers["503 verdict"] = memo.listing(for: key) { list(key) }
            }
        }
        if openBefore509 {
            memo.sharing { ruleEnd(); stretch() }
        } else {
            ruleEnd()
            memo.sharing { stretch() }
        }
        return (answers, changing ? changingStore.calls : store.calls.count)
    }

    private var shapes: [Shape] {
        var all: [Shape] = []
        for bits in 0..<32 {
            all.append(Shape(throughSeriesID: bits & 1 != 0, ruleEndChecked: bits & 2 != 0, baselineRuns: bits & 4 != 0,
                             verdictRuns: bits & 8 != 0, verdictOwnWindow: bits & 16 != 0))
        }
        return all
    }

    func testEveryReaderGetsMainsListingAndOneListingIsSavedExactlyWhere509AndTheBaselineShareAKey() {
        var saved = 0
        for shape in shapes {
            let main = run(shape, openBefore509: false), branch = run(shape, openBefore509: true)
            XCTAssertEqual(branch.answers, main.answers, "\(shape)")
            let shares = shape.throughSeriesID && shape.ruleEndChecked && (shape.baselineRuns || (shape.verdictRuns && !shape.verdictOwnWindow))
            XCTAssertEqual(branch.listings, main.listings - (shares ? 1 : 0), "\(shape)")
            if shares { saved += 1 }
        }
        XCTAssertGreaterThan(saved, 0)
    }

    // spec-example: series-listing-sharing / listings by call shape
    func testTheListingsOfTheSpecExample() {
        func listings(_ ruleEnd: Bool, _ baseline: Bool, verdict: Bool, ownWindow: Bool) -> (Int, Int) {
            let shape = Shape(throughSeriesID: true, ruleEndChecked: ruleEnd, baselineRuns: baseline, verdictRuns: verdict, verdictOwnWindow: ownWindow)
            return (run(shape, openBefore509: false).listings, run(shape, openBefore509: true).listings)
        }
        for (ruleEnd, baseline, verdict, ownWindow, before, now) in [(true, true, true, false, 2, 1), (true, true, true, true, 3, 2),
                                                                     (true, false, false, false, 1, 1), (false, true, true, false, 1, 1)] {
            let counts = listings(ruleEnd, baseline, verdict: verdict, ownWindow: ownWindow)
            XCTAssertEqual(counts.0, before, "main: \(ruleEnd) \(baseline) \(verdict) \(ownWindow)")
            XCTAssertEqual(counts.1, now, "branch: \(ruleEnd) \(baseline) \(verdict) \(ownWindow)")
        }
    }

    /// With a store another process writes to between listings, the two orders give the same answers
    /// except where #509 and a later reader ask for one key: there the later reader sees #509's listing
    /// (one generation earlier than `main` gave it). Everywhere else nothing differs.
    func testWithAChangingStoreTheAnswersDifferExactlyWhereAListingIsShared() {
        for shape in shapes {
            let main = run(shape, openBefore509: false, changing: true), branch = run(shape, openBefore509: true, changing: true)
            let shares = shape.throughSeriesID && shape.ruleEndChecked && (shape.baselineRuns || (shape.verdictRuns && !shape.verdictOwnWindow))
            XCTAssertEqual(branch.answers == main.answers, !shares, "\(shape)")
            if shares {
                XCTAssertEqual(branch.answers["509"], main.answers["509"], "#509 lists first in both: \(shape)")
                if shape.baselineRuns { XCTAssertEqual(branch.answers["503 baseline"], branch.answers["509"], "\(shape)") }
            }
        }
    }

    /// One memo over two calls of `updateEvent`: the second call lists again (nothing kept past a stretch).
    func testNothingIsKeptFromOneCallToTheNext() {
        let memo = SeriesListingMemo<[String]>()
        let shape = Shape(throughSeriesID: true, ruleEndChecked: true, baselineRuns: true, verdictRuns: true, verdictOwnWindow: false)
        let first = run(shape, openBefore509: true, changing: true, memo: memo)
        let second = run(shape, openBefore509: true, changing: true, memo: memo)
        XCTAssertEqual(first.listings, 1)
        XCTAssertEqual(second.listings, 1, "the second call lists for itself")
        XCTAssertFalse(memo.isSharing)
    }
}
