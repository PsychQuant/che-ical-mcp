import XCTest
@testable import CheICalMCP

/// #533: the #509 first-slot read and the #503 baseline ask `seriesOccurrences` for the same listing on
/// one route (span `all` through the series' id), and #527's stretch opened after the #509 read, so the
/// series was listed twice. A differential test over the call shapes: the readers' requests run through
/// `SeriesListingMemo` with a counting fake of the store, in `main`'s order (the #509 read before the
/// stretch) and in the branch's (the stretch opened before it). Each reader gets the same listing in
/// both, and the branch lists once less exactly where #509 and the baseline ask for the same key.
/// Where the readers sit in `updateEvent` is pinned in `SingleListingWiringTests`.
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

    /// The readers in `updateEvent`'s order; `openBefore509` is where the stretch opens.
    private func run(_ shape: Shape, openBefore509: Bool) -> (answers: [String: [String]], listings: Int) {
        let memo = SeriesListingMemo<[String]>()
        let store = CountingStore()
        var answers: [String: [String]] = [:]
        func ruleEnd() {
            if shape.throughSeriesID && shape.ruleEndChecked {
                answers["509"] = memo.listing(for: base) { store.list(base) }
            }
        }
        func stretch() {
            if shape.baselineRuns { answers["503 baseline"] = memo.listing(for: base) { store.list(base) } }
            if shape.verdictRuns {
                let key = shape.verdictOwnWindow ? horizon : base
                answers["503 verdict"] = memo.listing(for: key) { store.list(key) }
            }
        }
        if openBefore509 {
            memo.sharing { ruleEnd(); stretch() }
        } else {
            ruleEnd()
            memo.sharing { stretch() }
        }
        return (answers, store.calls.count)
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
        XCTAssertTrue(listings(true, true, verdict: true, ownWindow: false) == (2, 1))
        XCTAssertTrue(listings(true, true, verdict: true, ownWindow: true) == (3, 2))
        XCTAssertTrue(listings(true, false, verdict: false, ownWindow: false) == (1, 1))
        XCTAssertTrue(listings(false, true, verdict: true, ownWindow: false) == (1, 1))
    }
}
