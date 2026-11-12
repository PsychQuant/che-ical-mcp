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
        let window = UndoPostState.seriesScanWindow(firstStart: at("2026-01-05T10:00:00"), ruleEnd: nil)
        let horizon = DeletedOccurrenceCheck.horizon(now: now, calendar: calendar)!
        XCTAssertEqual(DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now),
                       SeriesExceptionsPlanner.listingRanges(for: window))
        XCTAssertEqual(DeletedOccurrenceCheck.listingRanges(window: window, horizon: nil, now: now),
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
        let ranges = DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now)
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
        let ranges = DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now)
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
                       .deleted(blocked: nil))
        // Past the horizon, still inside the listing.
        XCTAssertEqual(verdict(listed: oneBlock, observed: all.filter { $0 != at("2030-06-03T10:00:00") }, horizon: horizon),
                       .deleted(blocked: nil))
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
        // A deletion found in the listing before the gap still refuses the whole-series write.
        XCTAssertEqual(verdict(first: first, listed: [early, late], observed: observed.filter { $0 != at("2018-01-01T10:00:00") }, horizon: horizon),
                       .deleted(blocked: .notCovered))
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
        XCTAssertEqual(verdict(listed: oneBlock, observed: missing, horizon: horizon), .deleted(blocked: nil))
        XCTAssertEqual(verdict(listed: oneBlock, observed: missing, horizon: nil), .deleted(blocked: .notCovered), "as before")
        let short = [DateInterval(start: at("2025-01-01T00:00:00"), end: at("2028-06-01T00:00:00"))]
        XCTAssertEqual(verdict(listed: short, observed: missing.filter { $0 < at("2028-06-01T00:00:00") }, horizon: horizon),
                       .deleted(blocked: .notCovered))
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
        let notCovered = DeletedOccurrenceCheck.unknownCause(.notCovered)
        XCTAssertTrue(notCovered.contains("checked up to two years from now instead (#506)"), notCovered)
        let note = DeletedOccurrenceCheck.horizonNote(checkedUntil: "2031-11-15T00:00:00+08:00")
        XCTAssertTrue(note.contains("2031-11-15T00:00:00+08:00"), note)
        XCTAssertTrue(note.contains("was not checked and may have come back"), note)
        XCTAssertTrue(note.contains("#506"), note)
        XCTAssertFalse(note.lowercased().contains("complete"), note)
    }
}
