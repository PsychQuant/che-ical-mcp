import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// #506: a series the listing does not cover whole (open-ended, or ending about five years or more
/// after its start) was always refused a time change over more than one occurrence by #503. With a
/// horizon of now plus two years (maintainer, 2026-11-12), "no deletion found" is `noneThrough` when
/// the listing covers, without a gap, every slot the write reaches from its first reached slot up to
/// the horizon. Pure: no store.
final class DeletedOccurrenceHorizonTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Taipei")!
    private var calendar: Calendar { Calendar.gregorian(in: zone) }
    private let day: TimeInterval = 86_400

    private func at(_ text: String, offset: String = "+08:00") -> Date {
        ISO8601DateFormatter().date(from: text + offset)!
    }

    private let openWeekly = DeletedOccurrenceCheck.Rule(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [],
                                                        endDate: nil, occurrenceCount: 0, hasOtherParts: false)

    /// The route block of a `.deleted` verdict (`.some(nil)`: the route is offered), nil for any other verdict.
    private func block(_ verdict: DeletedOccurrenceCheck.Verdict) -> DeletedOccurrenceCheck.RouteBlock?? {
        if case .deleted(let blocked, _) = verdict { return .some(blocked) }
        return nil
    }

    /// An EKRecurrenceRule (no store needed) for the coverage helpers, weekly unless given.
    private func rule(_ frequency: EKRecurrenceFrequency = .weekly, end: Date? = nil, count: Int = 0,
                      daysOfMonth: [Int]? = nil, daysOfWeek: [EKWeekday]? = nil) -> EKRecurrenceRule {
        let recurrenceEnd = end.map { EKRecurrenceEnd(end: $0) } ?? (count > 0 ? EKRecurrenceEnd(occurrenceCount: count) : nil)
        return EKRecurrenceRule(recurrenceWith: frequency, interval: 1,
                                daysOfTheWeek: daysOfWeek.map { $0.map { EKRecurrenceDayOfWeek($0) } },
                                daysOfTheMonth: daysOfMonth.map { $0.map { NSNumber(value: $0) } }, monthsOfTheYear: nil,
                                weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: recurrenceEnd)
    }

    private func ranges(_ window: DateInterval, horizon: Date?, now: Date, rules: [EKRecurrenceRule], first: Date) -> [DateInterval] {
        DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now,
                                             rules: rules.map(DetachedOccurrenceSpan.RuleExtent.init), firstStart: first, calendar: calendar)
    }

    private func window(first: Date, end: Date?) -> DateInterval {
        UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: end)
    }

    // MARK: - The horizon

    func testTheHorizonIsTwoYearsFromNowOnTheWallClockOfTheSeriesZone() throws {
        XCTAssertEqual(DeletedOccurrenceCheck.horizonYears, 2)
        XCTAssertEqual(DeletedOccurrenceCheck.horizon(now: at("2026-11-12T10:00:00"), calendar: calendar), at("2028-11-12T10:00:00"))
        // February 29 has no day two years later: Foundation's year arithmetic takes February 28.
        XCTAssertEqual(DeletedOccurrenceCheck.horizon(now: at("2028-02-29T09:30:00"), calendar: calendar), at("2030-02-28T09:30:00"))
        // In a zone with daylight saving, the wall-clock time is kept (EST now, EST two years on; the
        // instant difference is two calendar years, not a fixed number of seconds).
        let newYork = Calendar.gregorian(in: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(DeletedOccurrenceCheck.horizon(now: at("2026-07-01T10:00:00", offset: "-04:00"), calendar: newYork),
                       at("2028-07-01T10:00:00", offset: "-04:00"))
    }

    // MARK: - The listing

    /// A series begun recently is listed as #503 lists it: the window from its first start already
    /// reaches past the horizon, so no range around now is added.
    func testAYoungSeriesIsListedAsBefore() {
        let now = at("2026-11-12T10:00:00")
        let first = at("2026-01-05T10:00:00")
        let window = UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: nil)
        let horizon = DeletedOccurrenceCheck.horizon(now: now, calendar: calendar)!
        XCTAssertEqual(ranges(window, horizon: horizon, now: now, rules: [rule()], first: first),
                       SeriesExceptionsPlanner.listingRanges(for: window))
        XCTAssertEqual(ranges(window, horizon: nil, now: now, rules: [rule()], first: first),
                       SeriesExceptionsPlanner.listingRanges(for: window), "no horizon: unchanged")
    }

    /// A series begun four years ago: its first-start listing ends about a year from now, so the range
    /// around now is added, and the two meet: the listing reaches past the horizon without a gap.
    func testAnOlderSeriesAddsARangeAroundNowThatReachesTheHorizon() throws {
        let now = at("2026-11-12T10:00:00")
        let first = at("2022-11-07T10:00:00")
        let window = UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: nil)
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: now, calendar: calendar))
        XCTAssertLessThan(SeriesExceptionsPlanner.listingRanges(for: window).map(\.end).max()!, horizon)
        let ranges = ranges(window, horizon: horizon, now: now, rules: [rule()], first: first)
        let end = try XCTUnwrap(DeletedOccurrenceCheck.listedEnd(of: ranges, from: first))
        XCTAssertGreaterThanOrEqual(end, horizon)
        // The range around now runs from 1094 days before now to a day past the horizon.
        XCTAssertEqual(DeletedOccurrenceCheck.windowAroundNow(now: now, horizon: horizon),
                       DateInterval(start: now.addingTimeInterval(-1094 * day), end: horizon.addingTimeInterval(day)))
        // Every range is one EventKit query long at most.
        XCTAssertTrue(ranges.allSatisfy { $0.duration <= 1460 * day }, "\(ranges)")
    }

    /// A series begun about ten years ago: the listing from its first start and the one around now
    /// leave a gap, so from its first start the listing does not reach the horizon.
    func testAVeryOldSeriesLeavesAGap() throws {
        let now = at("2026-11-12T10:00:00")
        let first = at("2016-11-07T10:00:00")
        let window = UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: nil)
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: now, calendar: calendar))
        let ranges = ranges(window, horizon: horizon, now: now, rules: [rule()], first: first)
        let fromFirst = try XCTUnwrap(DeletedOccurrenceCheck.listedEnd(of: ranges, from: first))
        XCTAssertLessThan(fromFirst, now, "the block from the first start ends before now")
        // From an occurrence near now (span future), the listing around now reaches the horizon.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(DeletedOccurrenceCheck.listedEnd(of: ranges, from: now)), horizon)
    }

    func testTheListedEndFollowsRangesThatMeetOrOverlap() {
        let a = DateInterval(start: at("2026-01-01T00:00:00"), end: at("2026-06-01T00:00:00"))
        let b = DateInterval(start: at("2026-06-01T00:00:00"), end: at("2026-09-01T00:00:00"))
        let c = DateInterval(start: at("2026-08-01T00:00:00"), end: at("2027-01-01T00:00:00"))
        let d = DateInterval(start: at("2027-03-01T00:00:00"), end: at("2027-04-01T00:00:00"))
        XCTAssertEqual(DeletedOccurrenceCheck.listedEnd(of: [d, c, a, b], from: at("2026-02-01T00:00:00")), at("2027-01-01T00:00:00"))
        XCTAssertEqual(DeletedOccurrenceCheck.listedEnd(of: [d, c, a, b], from: at("2027-03-01T00:00:00")), at("2027-04-01T00:00:00"))
        XCTAssertNil(DeletedOccurrenceCheck.listedEnd(of: [d, c, a, b], from: at("2027-01-01T00:00:00")), "the end is exclusive")
        XCTAssertNil(DeletedOccurrenceCheck.listedEnd(of: [a], from: at("2025-12-31T00:00:00")), "before the listing")
        XCTAssertNil(DeletedOccurrenceCheck.listedEnd(of: [], from: at("2026-02-01T00:00:00")))
    }

    // MARK: - The verdict

    private let horizon = ISO8601DateFormatter().date(from: "2028-11-12T10:00:00+08:00")!

    private func slots(from first: Date, until: Date) -> [Date] {
        DeletedOccurrenceCheck.expectedSlots(of: openWeekly, firstStart: first, until: until, calendar: calendar) ?? []
    }

    private func verdict(first: Date = ISO8601DateFormatter().date(from: "2026-01-05T10:00:00+08:00")!,
                         listed: [DateInterval], observed: [Date], reachedFrom: Date? = nil, horizon: Date?,
                         rules: [DeletedOccurrenceCheck.Rule]? = nil, covers: Bool = false) -> DeletedOccurrenceCheck.Verdict {
        DeletedOccurrenceCheck.verdict(rules: rules ?? [openWeekly], firstStart: first, observedSlots: observed, uneditedSlots: observed,
                                       slotsTrusted: true, changesAllDay: false, reachedFrom: reachedFrom,
                                       scannedTo: listed.map(\.end).max()!, coversWholeSeries: covers, calendar: calendar,
                                       listed: listed, horizon: horizon)
    }

    private var oneBlock: [DateInterval] {
        [DateInterval(start: at("2025-01-01T00:00:00"), end: at("2030-12-01T00:00:00"))]
    }

    func testAnOpenEndedSeriesWithNoDeletionUpToTheListingEndGoesThrough() {
        let end = at("2030-12-01T00:00:00")
        let all = slots(from: at("2026-01-05T10:00:00"), until: end)
        XCTAssertEqual(verdict(listed: oneBlock, observed: all, horizon: horizon), .noneThrough(end))
        // Without a horizon (another account, a new pattern) the series is still unknown, as before.
        XCTAssertEqual(verdict(listed: oneBlock, observed: all, horizon: nil), .unknown(.notCovered))
        // A series the listing covers whole is none, horizon or not.
        XCTAssertEqual(verdict(listed: oneBlock, observed: all, horizon: horizon, covers: true), .none)
    }

    func testADeletionAnywhereInTheListingRefuses() {
        let all = slots(from: at("2026-01-05T10:00:00"), until: at("2030-12-01T00:00:00"))
        // Inside the horizon.
        XCTAssertEqual(verdict(listed: oneBlock, observed: all.filter { $0 != at("2027-03-01T10:00:00") }, horizon: horizon),
                       .deleted(blocked: nil, routeWindow: DateInterval(start: at("2027-03-08T10:00:00"), end: at("2030-12-01T00:00:00"))))
        // Past the horizon, still inside the listing.
        XCTAssertEqual(verdict(listed: oneBlock, observed: all.filter { $0 != at("2030-06-03T10:00:00") }, horizon: horizon),
                       .deleted(blocked: nil, routeWindow: DateInterval(start: at("2030-06-10T10:00:00"), end: at("2030-12-01T00:00:00"))))
    }

    func testAListingThatEndsBeforeTheHorizonIsUnknown() {
        let short = [DateInterval(start: at("2025-01-01T00:00:00"), end: at("2028-06-01T00:00:00"))]
        let all = slots(from: at("2026-01-05T10:00:00"), until: at("2028-06-01T00:00:00"))
        XCTAssertEqual(verdict(listed: short, observed: all, horizon: horizon), .unknown(.horizonNotReached))
    }

    /// A gap between the listing from the first start and the one around now: the slots in the gap
    /// are not read as deletions, and a whole-series write is unknown; span future from an occurrence
    /// in the range around now goes through.
    func testAGapIsNotADeletionAndBlocksOnlyTheWritesThatReachIt() {
        let first = at("2016-11-07T10:00:00")
        let early = DateInterval(start: at("2015-11-01T00:00:00"), end: at("2021-11-01T00:00:00"))
        let late = DateInterval(start: at("2022-11-01T00:00:00"), end: at("2029-11-15T00:00:00"))
        let observed = slots(from: first, until: late.end).filter { early.contains($0) || late.contains($0) }
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed, horizon: horizon), .unknown(.horizonNotReached))
        let anchor = at("2026-11-16T10:00:00")
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed, reachedFrom: anchor, horizon: horizon),
                       .noneThrough(late.end))
        // A deletion found in the listing before the gap still refuses the whole-series write. Verify r1:
        // the refusal offers span future from an occurrence in the block around now, which reaches the
        // horizon and passes (gate step 6 measured that shape), not the first occurrence after the deletion.
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed.filter { $0 != at("2018-01-01T10:00:00") }, horizon: horizon),
                       .deleted(blocked: nil, routeWindow: DateInterval(start: at("2022-11-07T10:00:00"), end: late.end)))
    }

    /// Verify r1 (item 1): the route is taken from the first held, unedited occurrence after the last
    /// deletion whose unbroken listing reaches the horizon, and the refusal text names it.
    func testAnEarlyDeletionOffersTheRouteFromTheBlockAroundNow() {
        let first = at("2016-11-07T10:00:00")
        let early = DateInterval(start: at("2015-11-01T00:00:00"), end: at("2021-11-01T00:00:00"))
        let late = DateInterval(start: at("2022-11-01T00:00:00"), end: at("2029-11-15T00:00:00"))
        let observed = slots(from: first, until: late.end).filter { (early.contains($0) || late.contains($0)) && $0 != at("2019-03-04T10:00:00") }
        let refused = verdict(first: first, listed: [early, late], observed: observed, horizon: horizon)
        // Verify r2 (MEDIUM 1): the route window starts at the first occurrence in the block around now.
        let window = DateInterval(start: at("2022-11-07T10:00:00"), end: late.end)
        XCTAssertEqual(refused, .deleted(blocked: nil, routeWindow: window))
        let text = DeletedOccurrenceCheck.deletedReason(blocked: nil, routeWindow: (from: "2022-11-07T10:00:00+08:00", before: "2029-11-15T00:00:00+08:00"))
        XCTAssertEqual(SourcePins.ranges(of: "start from the occurrence on 2022-11-07T10:00:00+08:00, or a later one before 2029-11-15T00:00:00+08:00, that is not edited on its own:", in: text).count, 1, text)
        XCTAssertFalse(text.contains("the occurrence_date of an occurrence after it"), text)
        // The next occurrence after the deletion, the natural pick, is refused again: the text did not offer it.
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed, reachedFrom: at("2019-03-11T10:00:00"), horizon: horizon),
                       .unknown(.horizonNotReached))
        // A later one inside the window passes.
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed, reachedFrom: at("2027-06-07T10:00:00"), horizon: horizon),
                       .noneThrough(late.end))
        // On a series the listing covers, the text stays as on main.
        XCTAssertTrue(DeletedOccurrenceCheck.deletedReason(blocked: nil).contains("span 'future' with the occurrence_date of an occurrence after it, not edited on its own"))
        // The route it offers passes: span future from an occurrence in the block around now.
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed, reachedFrom: at("2026-11-16T10:00:00"), horizon: horizon),
                       .noneThrough(late.end))
        // Without the block around now, no occurrence after the deletion reaches the horizon.
        XCTAssertEqual(verdict(first: first, listed: [early], observed: observed.filter { early.contains($0) }, horizon: horizon),
                       .deleted(blocked: .horizonNotReached))
    }

    func testAnAnchorOutsideTheListingIsUnknown() {
        let all = slots(from: at("2026-01-05T10:00:00"), until: at("2030-12-01T00:00:00"))
        XCTAssertEqual(verdict(listed: oneBlock, observed: all, reachedFrom: at("2031-01-06T10:00:00"), horizon: horizon),
                       .unknown(.horizonNotReached))
    }

    /// The span-future route is offered when a write from an occurrence after the last deletion would
    /// itself reach the horizon, and not when it would not.
    func testTheRouteIsOfferedWhenItsWriteReachesTheHorizon() {
        let all = slots(from: at("2026-01-05T10:00:00"), until: at("2030-12-01T00:00:00"))
        let missing = all.filter { $0 != at("2026-03-02T10:00:00") }
        XCTAssertEqual(verdict(listed: oneBlock, observed: missing, horizon: horizon), .deleted(blocked: nil, routeWindow: DateInterval(start: at("2026-03-09T10:00:00"), end: at("2030-12-01T00:00:00"))))
        XCTAssertEqual(verdict(listed: oneBlock, observed: missing, horizon: nil), .deleted(blocked: .notCovered), "as before")
        let short = [DateInterval(start: at("2025-01-01T00:00:00"), end: at("2028-06-01T00:00:00"))]
        XCTAssertEqual(verdict(listed: short, observed: missing.filter { $0 < at("2028-06-01T00:00:00") }, horizon: horizon),
                       .deleted(blocked: .horizonNotReached))
    }

    /// Verify r1 (item 2): the no-horizon route text says the route was not evaluated against the
    /// two-year check; only the horizon case says the listing does not reach two years from now.
    func testTheRouteTextsSayWhetherTheHorizonWasEvaluated() {
        let notEvaluated = DeletedOccurrenceCheck.deletedReason(blocked: .notCovered)
        XCTAssertEqual(SourcePins.ranges(of: "was not evaluated against the two-year check (#506)", in: notEvaluated).count, 1, notEvaluated)
        XCTAssertFalse(notEvaluated.contains("does not reach two years from now"), notEvaluated)
        XCTAssertTrue(notEvaluated.contains("goes on past what this check can list"), notEvaluated)
        let reached = DeletedOccurrenceCheck.deletedReason(blocked: .horizonNotReached)
        XCTAssertEqual(SourcePins.ranges(of: "from no occurrence after the last deleted one does the listing reach two years from now without a gap (#506)", in: reached).count, 1, reached)
        XCTAssertFalse(reached.contains("was not evaluated"), reached)
        XCTAssertTrue(reached.contains("Nothing was written."), reached)
    }

    // MARK: - Coverage before the window around now (verify r1 item 4) and its computation (item 8)

    /// A bounded series main listed whole keeps main's ranges: no window around now is listed.
    func testASeriesTheBaseListingCoversKeepsMainsRanges() throws {
        let now = at("2026-11-12T10:00:00")
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: now, calendar: calendar))
        // Begun four years ago, ending in six months.
        let first = at("2022-11-07T10:00:00"), end = at("2027-05-10T10:00:00")
        let soon = window(first: first, end: end)
        XCTAssertEqual(ranges(soon, horizon: horizon, now: now, rules: [rule(end: end)], first: first),
                       SeriesExceptionsPlanner.listingRanges(for: soon))
        // Ended years ago.
        let oldFirst = at("2015-01-05T10:00:00"), oldEnd = at("2016-01-04T10:00:00")
        let ended = window(first: oldFirst, end: oldEnd)
        XCTAssertEqual(ranges(ended, horizon: horizon, now: now, rules: [rule(end: oldEnd)], first: oldFirst),
                       SeriesExceptionsPlanner.listingRanges(for: ended))
    }

    /// A series begun ten years ago that ends in a year: its listing has a gap, so it is not covered;
    /// taking the listing's last end (main's computation) would call it covered across the gap.
    func testCoverageIsTakenFromTheUnbrokenListingFromTheFirstStart() throws {
        let now = at("2026-11-12T10:00:00")
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: now, calendar: calendar))
        let first = at("2016-11-07T10:00:00"), end = at("2027-11-08T10:00:00")
        let rules = [rule(end: end)].map(DetachedOccurrenceSpan.RuleExtent.init)
        let listed = ranges(window(first: first, end: end), horizon: horizon, now: now, rules: [rule(end: end)], first: first)
        XCTAssertFalse(DeletedOccurrenceCheck.coversWholeSeries(rules: rules, firstStart: first, ranges: listed, calendar: calendar))
        XCTAssertTrue(DetachedOccurrenceSpan.coversWholeSeries(rules: rules, firstStart: first, scannedTo: listed.map(\.end).max()!, calendar: calendar),
                      "the last end alone would say covered")
    }

    /// Verify r1 (item 7): a bounded series begun about six years ago that ends in a year is listed
    /// whole once the window around now is added, so it answers `.none` (every occurrence compared),
    /// without the two fields.
    func testABoundedSeriesTheTwoListingsCoverAnswersNone() throws {
        let now = at("2026-11-12T10:00:00")
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: now, calendar: calendar))
        let first = at("2020-11-02T10:00:00"), end = at("2027-11-08T10:00:00")
        let ekRule = rule(end: end)
        let listed = ranges(window(first: first, end: end), horizon: horizon, now: now, rules: [ekRule], first: first)
        XCTAssertNotEqual(listed, SeriesExceptionsPlanner.listingRanges(for: window(first: first, end: end)), "the window around now is listed")
        let covers = DeletedOccurrenceCheck.coversWholeSeries(rules: [DetachedOccurrenceSpan.RuleExtent(ekRule)], firstStart: first,
                                                              ranges: listed, calendar: calendar)
        XCTAssertTrue(covers)
        let checkRule = DeletedOccurrenceCheck.Rule(ekRule)
        let all = DeletedOccurrenceCheck.expectedSlots(of: checkRule, firstStart: first, until: listed.map(\.end).max()!, calendar: calendar) ?? []
        XCTAssertEqual(DeletedOccurrenceCheck.verdict(rules: [checkRule], firstStart: first, observedSlots: all, uneditedSlots: all, slotsTrusted: true,
                                                      changesAllDay: false, reachedFrom: nil, scannedTo: listed.map(\.end).max()!,
                                                      coversWholeSeries: covers, calendar: calendar, listed: listed, horizon: horizon), .none)
    }

    /// Verify r1 (item 8): an end_date more than five years out, and a count the check cannot place,
    /// are not covered and are checked up to the horizon.
    func testAFarEndAndAnUnplaceableCountAreCheckedUpToTheHorizon() throws {
        let now = at("2026-11-12T10:00:00")
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: now, calendar: calendar))
        let cases: [(String, EKRecurrenceRule, Date)] = [
            ("end_date seven years out", rule(end: at("2033-12-12T10:00:00")), at("2026-12-07T10:00:00")),
            ("monthly days 5 and 20, count 150", rule(.monthly, count: 150, daysOfMonth: [5, 20]), at("2026-12-05T10:00:00")),
        ]
        for (name, ekRule, first) in cases {
            let extent = DetachedOccurrenceSpan.RuleExtent(ekRule)
            let listed = ranges(window(first: first, end: ekRule.recurrenceEnd?.endDate), horizon: horizon, now: now, rules: [ekRule], first: first)
            let covers = DeletedOccurrenceCheck.coversWholeSeries(rules: [extent], firstStart: first, ranges: listed, calendar: calendar)
            XCTAssertFalse(covers, name)
            let checkRule = DeletedOccurrenceCheck.Rule(ekRule)
            let end = listed.map(\.end).max()!
            let all = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: checkRule, firstStart: first, until: end, calendar: calendar), name)
            func check(_ observed: [Date]) -> DeletedOccurrenceCheck.Verdict {
                DeletedOccurrenceCheck.verdict(rules: [checkRule], firstStart: first, observedSlots: observed, uneditedSlots: observed, slotsTrusted: true,
                                               changesAllDay: false, reachedFrom: nil, scannedTo: end, coversWholeSeries: covers,
                                               calendar: calendar, listed: listed, horizon: horizon)
            }
            XCTAssertEqual(check(all), .noneThrough(try XCTUnwrap(DeletedOccurrenceCheck.listedEnd(of: listed, from: first))), name)
            XCTAssertEqual(block(check(all.enumerated().filter { $0.offset != 3 }.map(\.element))),
                           .some(nil), name)
        }
    }

    /// Verify r1 (item 8): an all-day series with a horizon, built in the host zone. Verify r2 (LOW 4):
    /// the test builds everything in that one calendar, so the host run and the TZ=UTC run take the same
    /// code path; it does not exercise a daylight-saving change or `UndoPostState.ruleSlot`.
    func testAnAllDaySeriesInTheHostZoneIsCheckedUpToTheHorizon() throws {
        let host = Calendar.gregorian(in: .current)
        let first = try XCTUnwrap(host.date(from: DateComponents(year: 2026, month: 12, day: 7)))
        let rule = DeletedOccurrenceCheck.Rule(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                               occurrenceCount: 0, hasOtherParts: false)
        let listedEnd = try XCTUnwrap(host.date(byAdding: .day, value: 1826, to: first))
        let listed = [DateInterval(start: first.addingTimeInterval(-367 * day), end: listedEnd)]
        let horizon = try XCTUnwrap(DeletedOccurrenceCheck.horizon(now: first, calendar: host))
        let all = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule, firstStart: first, until: listedEnd, calendar: host))
        XCTAssertTrue(all.allSatisfy { host.component(.hour, from: $0) == 0 }, "local midnights, whatever the host zone")
        func check(_ observed: [Date]) -> DeletedOccurrenceCheck.Verdict {
            DeletedOccurrenceCheck.verdict(rules: [rule], firstStart: first, observedSlots: observed, uneditedSlots: observed, slotsTrusted: true,
                                           changesAllDay: false, reachedFrom: nil, scannedTo: listedEnd, coversWholeSeries: false,
                                           calendar: host, isAllDay: true, listed: listed, horizon: horizon)
        }
        XCTAssertEqual(check(all), .noneThrough(listedEnd))
        XCTAssertEqual(block(check(all.enumerated().filter { $0.offset != 20 }.map(\.element))), .some(nil))
    }

    /// Verify r2 (LOW 3): on a series the listing does not cover, no occurrence after the last deletion,
    /// or only edited ones, is `nothingAfter` (its text is the reason), not `horizonNotReached`.
    func testNoOccurrenceAfterTheDeletionIsNothingAfterOnAnUncoveredSeries() {
        let all = slots(from: at("2026-01-05T10:00:00"), until: at("2030-12-01T00:00:00"))
        let lastDeleted = Array(all.dropLast())
        XCTAssertEqual(verdict(listed: oneBlock, observed: lastDeleted, horizon: horizon), .deleted(blocked: .nothingAfter))
        let missing = at("2027-03-01T10:00:00")
        let observed = all.filter { $0 != missing }
        let unedited = observed.filter { $0 < missing }
        XCTAssertEqual(DeletedOccurrenceCheck.verdict(rules: [openWeekly], firstStart: at("2026-01-05T10:00:00"), observedSlots: observed,
                                                      uneditedSlots: unedited, slotsTrusted: true, changesAllDay: false, reachedFrom: nil,
                                                      scannedTo: at("2030-12-01T00:00:00"), coversWholeSeries: false, calendar: calendar,
                                                      listed: oneBlock, horizon: horizon),
                       .deleted(blocked: .nothingAfter))
    }

    // MARK: - The expansion cap (verify r1 item 6)

    /// Verify r2 (LOW 1): exactly `maxSlots` slots in range is not too many; a slot more is.
    func testTheCapCountsOnlyASlotPastIt() throws {
        let first = at("1970-01-05T10:00:00")
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                                occurrenceCount: 0, hasOtherParts: false)
        let exact = try XCTUnwrap(calendar.date(byAdding: .day, value: DeletedOccurrenceCheck.maxSlots - 1, to: first)).addingTimeInterval(1)
        guard case .slots(let slots) = DeletedOccurrenceCheck.expansion(of: daily, firstStart: first, until: exact, calendar: calendar) else {
            return XCTFail("exactly \(DeletedOccurrenceCheck.maxSlots) slots must expand")
        }
        XCTAssertEqual(slots.count, DeletedOccurrenceCheck.maxSlots)
        let oneMore = try XCTUnwrap(calendar.date(byAdding: .day, value: DeletedOccurrenceCheck.maxSlots, to: first)).addingTimeInterval(1)
        XCTAssertEqual(DeletedOccurrenceCheck.expansion(of: daily, firstStart: first, until: oneMore, calendar: calendar), .tooMany)
    }

    /// A daily series old enough to pass 20,000 slots before the end of the listing is unknown with a
    /// cause of its own, never `noneThrough` over occurrences it did not expand.
    func testASeriesPastTheExpansionCapIsUnknown() {
        let first = at("1965-01-04T10:00:00")
        let daily = DeletedOccurrenceCheck.Rule(frequency: .daily, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                                occurrenceCount: 0, hasOtherParts: false)
        let listed = [DateInterval(start: at("2022-11-01T00:00:00"), end: at("2029-11-15T00:00:00"))]
        XCTAssertNil(DeletedOccurrenceCheck.expectedSlots(of: daily, firstStart: first, until: at("2029-11-15T00:00:00"), calendar: calendar))
        XCTAssertEqual(DeletedOccurrenceCheck.expansion(of: daily, firstStart: first, until: at("2029-11-15T00:00:00"), calendar: calendar), .tooMany)
        // Every listed occurrence held: the occurrences around now were never expanded, so nothing may pass.
        var observed: [Date] = []
        var d = at("2022-11-01T10:00:00")
        while d < at("2029-11-15T00:00:00") { observed.append(d); d = calendar.date(byAdding: .day, value: 1, to: d)! }
        let result = DeletedOccurrenceCheck.verdict(rules: [daily], firstStart: first, observedSlots: observed, uneditedSlots: observed,
                                                    slotsTrusted: true, changesAllDay: false, reachedFrom: at("2026-11-16T10:00:00"),
                                                    scannedTo: at("2029-11-15T00:00:00"), coversWholeSeries: false, calendar: calendar,
                                                    listed: listed, horizon: horizon)
        XCTAssertEqual(result, .unknown(.tooManySlots))
        let reason = DeletedOccurrenceCheck.unknownReason(.tooManySlots)
        XCTAssertTrue(reason.contains("more occurrences than the check expands (20000)"), reason)
        // A short series is unaffected.
        XCTAssertNotNil(DeletedOccurrenceCheck.expectedSlots(of: daily, firstStart: at("2026-01-05T10:00:00"), until: at("2029-11-15T00:00:00"), calendar: calendar))
    }

    /// Every other #503 cause still answers first.
    func testTheOtherUnknownCausesStillApply() {
        let all = slots(from: at("2026-01-05T10:00:00"), until: at("2030-12-01T00:00:00"))
        let numbered = DeletedOccurrenceCheck.Rule(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                                   occurrenceCount: 0, hasOtherParts: true)
        XCTAssertEqual(verdict(listed: oneBlock, observed: all, horizon: horizon, rules: [numbered]), .unknown(.ruleNotFollowed))
        XCTAssertEqual(verdict(listed: oneBlock, observed: all, horizon: horizon, rules: [openWeekly, openWeekly]), .unknown(.ruleNotFollowed))
        XCTAssertEqual(verdict(listed: oneBlock, observed: all + [at("2026-01-07T10:00:00")], horizon: horizon), .unknown(.listedOffRule))
        XCTAssertEqual(DeletedOccurrenceCheck.verdict(
            rules: [openWeekly], firstStart: nil, observedSlots: all, uneditedSlots: all, slotsTrusted: true, changesAllDay: false,
            reachedFrom: nil, scannedTo: at("2030-12-01T00:00:00"), coversWholeSeries: false, calendar: calendar,
            firstSlotCause: .standIn, listed: oneBlock, horizon: horizon), .unknown(.firstSlot(.standIn)))
        XCTAssertEqual(DeletedOccurrenceCheck.verdict(
            rules: [openWeekly], firstStart: at("2026-01-05T10:00:00"), observedSlots: all, uneditedSlots: all, slotsTrusted: false,
            changesAllDay: false, reachedFrom: nil, scannedTo: at("2030-12-01T00:00:00"), coversWholeSeries: false, calendar: calendar,
            listed: oneBlock, horizon: horizon), .unknown(.editedWithoutSlot))
    }

    // MARK: - Texts

    func testTheTextsNameTheHorizonAndDoNotCallTheCheckComplete() {
        let unknown = DeletedOccurrenceCheck.unknownReason(.horizonNotReached)
        XCTAssertTrue(unknown.contains("Nothing was written."), unknown)
        XCTAssertTrue(unknown.contains("two years from now"), unknown)
        XCTAssertTrue(unknown.contains("#506"), unknown)
        // notCovered is now only the cause without a horizon; it says when the horizon applies.
        // Verify r2 (LOW 2): the window around now is listed only when the first-start listing ends before the horizon.
        XCTAssertTrue(DeletedOccurrenceCheck.unknownCause(.horizonNotReached).contains("and, when that ends before two years from now, also around now from about four years before"))
        let notCovered = DeletedOccurrenceCheck.unknownCause(.notCovered)
        XCTAssertTrue(notCovered.contains("checked up to two years from now instead (#506)"), notCovered)
        let note = DeletedOccurrenceCheck.horizonNote(checkedUntil: "2031-11-15T00:00:00+08:00")
        XCTAssertTrue(note.contains("2031-11-15T00:00:00+08:00"), note)
        XCTAssertTrue(note.contains("was not checked and may have come back"), note)
        XCTAssertTrue(note.contains("#506"), note)
        XCTAssertFalse(note.lowercased().contains("complete"), note)
    }
}
