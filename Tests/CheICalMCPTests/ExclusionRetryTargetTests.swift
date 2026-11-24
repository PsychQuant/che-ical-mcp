import XCTest
@testable import CheICalMCP

/// #544: which series a `create_event` retry with exclusions is checked against.
final class ExclusionRetryTargetTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private struct Raised: Error, Equatable {}

    /// 2026-12-07 10:00 +08:00, the `/RID=` of the edited first occurrence read on iCloud (2026-11-23).
    private let requested = Date(timeIntervalSinceReferenceDate: 818_301_600)
    private let firstID = "S/RID=818301600"
    private let title = "#544 weekly"

    /// The series lookup that records what it was asked for.
    private final class Lookup {
        var asked: [String] = []
        let answer: ExclusionRetryTarget.SeriesFacts?
        init(_ answer: ExclusionRetryTarget.SeriesFacts?) { self.answer = answer }
        func read(_ id: String) -> ExclusionRetryTarget.SeriesFacts? { asked.append(id); return answer }
    }

    private func facts(title: String? = "#544 weekly", rules: Bool = true, zone: TimeZone? = nil, allDay: Bool = false,
                       firstStart: Date? = nil) -> ExclusionRetryTarget.SeriesFacts {
        ExclusionRetryTarget.SeriesFacts(hasRecurrenceRules: rules, timeZone: zone, title: title, isAllDay: allDay,
                                         firstStart: firstStart ?? requested)
    }

    private func match(_ id: String, detached: Bool = true, rules: Bool = false, zone: TimeZone? = nil, start: Date? = nil) -> ExclusionRetryTarget.Match {
        ExclusionRetryTarget.Match(identifier: id, isDetached: detached, hasRecurrenceRules: rules, timeZone: zone, start: start ?? requested)
    }

    private func request(start: Date? = nil, title: String? = nil, host: TimeZone? = nil) -> ExclusionRetryTarget.Request {
        ExclusionRetryTarget.Request(title: title ?? self.title, start: start ?? requested, host: host ?? taipei)
    }

    /// A match with rules of its own that addresses no occurrence is the series, under its own
    /// identifier and zone, and the series lookup is not made (the path of `main`).
    func testAMatchWithRulesIsCheckedAgainstItself() {
        let lookup = Lookup(facts(zone: tokyo))
        let target = ExclusionRetryTarget.resolve(match: match("S", detached: false, rules: true, zone: taipei), request: request(), series: lookup.read)
        XCTAssertEqual(target, .series(id: "S", zone: taipei))
        XCTAssertEqual(lookup.asked, [])
    }

    // spec-example: recurrence-excluded-dates / target of the check
    /// The issue's shape: the series' first occurrence edited in place matched. The series named
    /// before `/RID=` is checked, in the series' zone, not the occurrence's.
    func testTheFirstOccurrenceEditedInPlaceIsCheckedAgainstItsSeries() {
        let lookup = Lookup(facts(zone: taipei))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID, zone: tokyo), request: request(), series: lookup.read),
                       .series(id: "S", zone: taipei))
        XCTAssertEqual(lookup.asked, ["S"])
    }

    /// X1 (a): an occurrence of another series, retitled on its own to the requested title, at the
    /// requested start. Its slot is the requested start, but its series has another title: not checked.
    func testAnOccurrenceOfAnotherSeriesRetitledOnItsOwnIsNotChecked() {
        let lookup = Lookup(facts(title: "Other"))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID), request: request(), series: lookup.read),
                       .notChecked(occurrenceID: firstID))
        XCTAssertEqual(lookup.asked, ["S"])
    }

    /// Y1 (verify round 2): a later occurrence of another same-titled series, edited in place at the
    /// requested start. Its slot and start are the requested start, but the series' first slot is a
    /// week earlier: not the series' first occurrence, not checked. A series object that reads no
    /// first slot is not checked either.
    func testALaterOccurrenceEditedInPlaceIsNotChecked() {
        let weekEarlier = requested.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID), request: request(),
                                                    series: Lookup(facts(firstStart: weekEarlier)).read),
                       .notChecked(occurrenceID: firstID))
        let noFirst = ExclusionRetryTarget.SeriesFacts(hasRecurrenceRules: true, timeZone: nil, title: title, isAllDay: false, firstStart: nil)
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID), request: request(), series: Lookup(noFirst).read),
                       .notChecked(occurrenceID: firstID))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID), request: request(),
                                                    series: Lookup(facts(firstStart: requested.addingTimeInterval(0.5))).read),
                       .series(id: "S", zone: nil))
    }

    /// X1 (b): an occurrence of an older series with the same title, moved on its own onto the
    /// requested start (a Saturday occurrence moved to the Monday of the request). Its slot, read
    /// from `/RID=`, is not the requested start.
    func testAnOccurrenceMovedOntoTheRequestedStartIsNotChecked() {
        let moved = "S/RID=\(818_301_600 - 2 * 86_400)"
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(moved), request: request(), series: Lookup(facts()).read),
                       .notChecked(occurrenceID: moved))
    }

    /// The first occurrence moved within the lookup's window (its start is not its slot): not edited
    /// in place, so not checked. An instant within one second counts as the same.
    func testAFirstOccurrenceMovedWithinTheWindowIsNotChecked() {
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID, start: requested.addingTimeInterval(20)), request: request(),
                                                    series: Lookup(facts()).read),
                       .notChecked(occurrenceID: firstID))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID, start: requested.addingTimeInterval(0.5)), request: request(),
                                                    series: Lookup(facts()).read),
                       .series(id: "S", zone: nil))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID), request: request(start: requested.addingTimeInterval(20)),
                                                    series: Lookup(facts()).read),
                       .notChecked(occurrenceID: firstID))
    }

    /// An all-day series' `/RID=` is the wall-clock date read as UTC (#285): it is read on this
    /// Mac's day, the day the all-day request starts on, on hosts west and east of UTC.
    func testAnAllDayFirstOccurrenceIsReadOnTheHostDay() {
        let midnightUTC = 818_294_400 // 2026-12-07 00:00 UTC
        let id = "S/RID=\(midnightUTC)"
        for host in [taipei, losAngeles, TimeZone(identifier: "UTC")!] {
            var day = Calendar(identifier: .gregorian); day.timeZone = host
            let start = day.date(from: DateComponents(year: 2026, month: 12, day: 7))!
            XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(id, start: start), request: request(start: start, host: host),
                                                        series: Lookup(facts(allDay: true, firstStart: start)).read),
                           .series(id: "S", zone: nil), host.identifier)
            // The raw instant would be the evening before west of UTC; read as a timed slot it does not match.
            XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(id, start: start), request: request(start: start, host: host),
                                                        series: Lookup(facts(allDay: false, firstStart: start)).read) == .series(id: "S", zone: nil),
                           host.secondsFromGMT() == 0, host.identifier)
        }
    }

    /// X4: a match that addresses one occurrence is read through its series even when it reports
    /// rules of its own (no store was measured to do so), not checked under its own identifier.
    func testADetachedMatchThatReportsRulesGoesThroughItsSeries() {
        let lookup = Lookup(facts(zone: taipei))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID, rules: true, zone: tokyo), request: request(), series: lookup.read),
                       .series(id: "S", zone: taipei))
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID, rules: true), request: request(), series: Lookup(facts(title: "Other")).read),
                       .notChecked(occurrenceID: firstID))
        XCTAssertEqual(lookup.asked, ["S"])
    }

    /// A `/RID=` identifier is enough when the object does not report itself detached, and a
    /// detached object without `/RID=` names no series.
    func testEitherSignalAddressesOneOccurrence() {
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID, detached: false), request: request(), series: Lookup(facts()).read),
                       .series(id: "S", zone: nil))
        let unnamed = Lookup(facts())
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match("OTHER-1"), request: request(), series: unnamed.read),
                       .notChecked(occurrenceID: "OTHER-1"))
        XCTAssertEqual(unnamed.asked, [])
    }

    /// The series object is missing, or reads without rules: not checked.
    func testASeriesThatDoesNotReadAsRecurringIsNotChecked() {
        for answer in [nil, facts(rules: false)] {
            let lookup = Lookup(answer)
            XCTAssertEqual(ExclusionRetryTarget.resolve(match: match(firstID), request: request(), series: lookup.read),
                           .notChecked(occurrenceID: firstID), "\(String(describing: answer))")
            XCTAssertEqual(lookup.asked, ["S"])
        }
    }

    /// A one-off match keeps the conflict of #182 verify finding 8, and no series is looked up.
    func testAOneOffMatchKeepsTheConflict() {
        let lookup = Lookup(facts())
        XCTAssertEqual(ExclusionRetryTarget.resolve(match: match("ONE", detached: false, zone: taipei), request: request(), series: lookup.read),
                       .notRecurring(id: "ONE"))
        XCTAssertEqual(lookup.asked, [])
    }

    /// A lookup that raised (#288) is passed on, not read as a missing series.
    func testALookupThatRaisedIsPassedOn() {
        XCTAssertThrowsError(try ExclusionRetryTarget.resolve(match: match(firstID), request: request(), series: { _ in throw Raised() })) { error in
            XCTAssertEqual(error as? Raised, Raised())
        }
    }

    /// The text names the occurrence only in the shape #532 echoes, says what the check needs, that
    /// it did not run and that nothing was written, and carries no `<`, `>` or `&` (#166).
    func testTheNotCheckedText() {
        let named = ExclusionRetryTarget.notCheckedReason(occurrenceID: "6F2A:9B1C/RID=811648800")
        XCTAssertEqual(named, "An occurrence edited on its own (event ID 6F2A:9B1C/RID=811648800) matches this event. A retry is checked against the series of such an occurrence only when it is that series' first occurrence, edited in place (its original start and its start are the requested start), and the series reads as a recurring series with the requested title; that was not shown, so the excluded dates were not checked. Nothing was created or modified; check the series in Calendar or change the request.")
        for id in ["OTHER-1", "S/RID=81164x800", "S/RID=1/RID=2", "S <b>/RID=1"] {
            let text = ExclusionRetryTarget.notCheckedReason(occurrenceID: id)
            XCTAssertTrue(text.hasPrefix("An occurrence edited on its own (the id list_events shows for it) matches this event."), text)
            XCTAssertFalse(text.contains(id), text)
        }
        XCTAssertFalse(named.contains("<") || named.contains(">") || named.contains("&"))
        XCTAssertEqual(EventKitError.exclusionRetryNotChecked(occurrenceId: "6F2A:9B1C/RID=811648800").errorDescription, named)
    }
}
