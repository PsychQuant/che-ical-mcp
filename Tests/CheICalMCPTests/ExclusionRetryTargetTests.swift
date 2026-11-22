import XCTest
@testable import CheICalMCP

/// #544: which series a `create_event` retry with exclusions is checked against.
final class ExclusionRetryTargetTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private struct Raised: Error, Equatable {}

    /// The series lookup that records what it was asked for.
    private final class Lookup {
        var asked: [String] = []
        let answer: ExclusionRetryTarget.SeriesFacts?
        init(_ answer: ExclusionRetryTarget.SeriesFacts?) { self.answer = answer }
        func read(_ id: String) -> ExclusionRetryTarget.SeriesFacts? { asked.append(id); return answer }
    }

    /// A match with rules of its own is the series, under its own identifier and zone, and the
    /// series lookup is not made (the path of `main`).
    func testAMatchWithRulesIsCheckedAgainstItself() {
        let lookup = Lookup(.init(hasRecurrenceRules: true, timeZone: tokyo))
        let target = ExclusionRetryTarget.resolve(matchID: "S", matchIsDetached: false, matchHasRules: true, matchZone: taipei, series: lookup.read)
        XCTAssertEqual(target, .series(id: "S", zone: taipei))
        XCTAssertEqual(lookup.asked, [])
    }

    /// The issue's shape: the edited first occurrence matched. The series named before `/RID=` is
    /// checked, in the series' zone, not the occurrence's.
    func testAnEditedOccurrenceIsCheckedAgainstItsSeries() {
        let lookup = Lookup(.init(hasRecurrenceRules: true, timeZone: taipei))
        let target = ExclusionRetryTarget.resolve(matchID: "S/RID=811648800", matchIsDetached: true, matchHasRules: false,
                                                  matchZone: tokyo, series: lookup.read)
        XCTAssertEqual(target, .series(id: "S", zone: taipei))
        XCTAssertEqual(lookup.asked, ["S"])
    }

    /// A `/RID=` identifier is enough when the object does not report itself detached, and a
    /// detached object without `/RID=` names no series.
    func testEitherSignalAddressesOneOccurrence() {
        let found = Lookup(.init(hasRecurrenceRules: true, timeZone: nil))
        XCTAssertEqual(ExclusionRetryTarget.resolve(matchID: "S/RID=811648800", matchIsDetached: false, matchHasRules: false,
                                                    matchZone: nil, series: found.read),
                       .series(id: "S", zone: nil))
        let unnamed = Lookup(.init(hasRecurrenceRules: true, timeZone: nil))
        XCTAssertEqual(ExclusionRetryTarget.resolve(matchID: "OTHER-1", matchIsDetached: true, matchHasRules: false,
                                                    matchZone: nil, series: unnamed.read),
                       .seriesUnread(occurrenceID: "OTHER-1"))
        XCTAssertEqual(unnamed.asked, [])
    }

    /// The series object is missing, or reads without rules: the check does not run.
    func testASeriesThatDoesNotReadAsRecurringIsUnread() {
        for answer in [nil, ExclusionRetryTarget.SeriesFacts(hasRecurrenceRules: false, timeZone: taipei)] {
            let lookup = Lookup(answer)
            XCTAssertEqual(ExclusionRetryTarget.resolve(matchID: "S/RID=811648800", matchIsDetached: true, matchHasRules: false,
                                                        matchZone: nil, series: lookup.read),
                           .seriesUnread(occurrenceID: "S/RID=811648800"), "\(String(describing: answer))")
            XCTAssertEqual(lookup.asked, ["S"])
        }
    }

    /// A one-off match keeps the conflict of #182 verify finding 8, and no series is looked up.
    func testAOneOffMatchKeepsTheConflict() {
        let lookup = Lookup(.init(hasRecurrenceRules: true, timeZone: nil))
        XCTAssertEqual(ExclusionRetryTarget.resolve(matchID: "ONE", matchIsDetached: false, matchHasRules: false,
                                                    matchZone: taipei, series: lookup.read),
                       .notRecurring(id: "ONE"))
        XCTAssertEqual(lookup.asked, [])
    }

    /// A lookup that raised (#288) is passed on, not read as a missing series.
    func testALookupThatRaisedIsPassedOn() {
        XCTAssertThrowsError(try ExclusionRetryTarget.resolve(matchID: "S/RID=811648800", matchIsDetached: true, matchHasRules: false,
                                                              matchZone: nil, series: { _ in throw Raised() })) { error in
            XCTAssertEqual(error as? Raised, Raised())
        }
    }

    /// The text names the occurrence only in the shape #532 echoes, says the check did not run and
    /// that nothing was written, and carries no `<`, `>` or `&` (#166).
    func testTheUnreadText() {
        let named = ExclusionRetryTarget.seriesUnreadReason(occurrenceID: "6F2A:9B1C/RID=811648800")
        XCTAssertEqual(named, "An occurrence edited on its own (event ID 6F2A:9B1C/RID=811648800) matches this event, and the series it belongs to could not be read as a recurring series, so the excluded dates were not checked. Nothing was created or modified; check the series in Calendar or change the request.")
        for id in ["OTHER-1", "S/RID=81164x800", "S/RID=1/RID=2", "S <b>/RID=1"] {
            let text = ExclusionRetryTarget.seriesUnreadReason(occurrenceID: id)
            XCTAssertTrue(text.hasPrefix("An occurrence edited on its own (the id list_events shows for it) matches this event"), text)
            XCTAssertFalse(text.contains(id), text)
        }
        XCTAssertFalse(named.contains("<") || named.contains(">") || named.contains("&"))
        XCTAssertEqual(EventKitError.exclusionSeriesUnread(occurrenceId: "6F2A:9B1C/RID=811648800").errorDescription, named)
    }
}
