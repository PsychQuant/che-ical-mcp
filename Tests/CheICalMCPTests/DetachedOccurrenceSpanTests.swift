import EventKit
import XCTest
@testable import CheICalMCP

/// #416: writes that take a span, addressed through the identifier of an occurrence that was edited
/// on its own. Measured on device (iCloud, 2026-11-05) against `main` without these refusals:
///
/// | Occurrence (its own id) | `update_event` span `all` | `delete_event` / batch span `all` |
/// |---|---|---|
/// | middle, earlier ones remain | split; only it and the later ones updated | only it deleted, answered "all" |
/// | first | every occurrence updated, id kept | only it deleted, answered "all" |
/// | first left, first one deleted | every remaining one updated, new id | only it deleted, answered "all" |
/// | the only one left | it updated, new id | it deleted |
///
/// What is refused is what did something other than what the caller asked for: update span `all`
/// with an earlier occurrence left, delete span `all` with any other occurrence left. Span `future`
/// through such an identifier does what the span says and is not refused, except for dates, which
/// are refused with span `all` and `future` (PR #431 round 4). These are the coordinator's defaults
/// while the maintainer has not answered.
///
/// The neighbours come from a scan of the series. An occurrence with no series to scan (no `/RID=`
/// on a source without it, which Exchange may be; #320 measured `/RID=` on Google) has unknown
/// neighbours and is refused: nothing is written.
final class DetachedOccurrenceSpanTests: XCTestCase {
    private let series = "CAL-1:SERIES-1"
    private let iCloudOccurrence = "CAL-1:SERIES-1/RID=826768800"
    /// The shape a source without `/RID=` would give, which #320 did not measure (Exchange).
    private let otherSourceOccurrence = "CAL-2:OCCURRENCE-7"

    private let day: TimeInterval = 86_400

    private func unedited(_ days: Double) -> FirstRemainingOccurrence.Candidate {
        .init(eventIdentifier: series, isDetached: false, hasRecurrenceRules: true,
              start: Date(timeIntervalSinceReferenceDate: days * day))
    }

    private func edited(_ days: Double, id: String? = nil, start: Double? = nil) -> FirstRemainingOccurrence.Candidate {
        let slot = Date(timeIntervalSinceReferenceDate: days * day)
        return .init(eventIdentifier: id ?? "\(series)/RID=\(Int(days * day))", isDetached: true, hasRecurrenceRules: false,
                     start: start.map { Date(timeIntervalSinceReferenceDate: $0 * day) } ?? slot, slot: slot)
    }

    private func neighbours(of own: FirstRemainingOccurrence.Candidate,
                            among others: [FirstRemainingOccurrence.Candidate],
                            covers: Bool = true, named: Set<String> = []) -> DetachedOccurrenceSpan.Neighbours? {
        DetachedOccurrenceSpan.neighbours(of: own.eventIdentifier ?? "", slot: own.slot ?? own.start, among: others + [own],
                                          coversWholeSeries: covers, namedInTheCall: named)
    }

    private let earlier = DetachedOccurrenceSpan.Neighbours(earlierRemain: true, othersRemain: true)
    private let noneEarlier = DetachedOccurrenceSpan.Neighbours(earlierRemain: false, othersRemain: true)
    private let alone = DetachedOccurrenceSpan.Neighbours(earlierRemain: false, othersRemain: false)

    // MARK: - Recognizing an occurrence

    func testAnOccurrenceIsRecognizedByIsDetachedOrByItsRIDSlot() {
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: iCloudOccurrence, isDetached: true))
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: iCloudOccurrence, isDetached: false),
                      "the /RID= slot alone is enough")
        XCTAssertTrue(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: otherSourceOccurrence, isDetached: true),
                      "isDetached alone is enough (a source with no /RID=)")
        XCTAssertFalse(DetachedOccurrenceSpan.addressesOneOccurrence(identifier: series, isDetached: false))
    }

    func testTheSeriesIdentifierIsThePartBeforeTheSlot() {
        XCTAssertEqual(DetachedOccurrenceSpan.seriesIdentifier(of: iCloudOccurrence), series)
        XCTAssertNil(DetachedOccurrenceSpan.seriesIdentifier(of: otherSourceOccurrence), "nothing to derive it from")
        XCTAssertNil(DetachedOccurrenceSpan.seriesIdentifier(of: "/RID=1"), "an empty series identifier is none")
    }

    // MARK: - Neighbours (the measured shapes)

    func testTheFourMeasuredShapes() {
        XCTAssertEqual(neighbours(of: edited(14), among: [unedited(0), unedited(7), unedited(21), unedited(28)]), earlier)
        XCTAssertEqual(neighbours(of: edited(0), among: [unedited(7), unedited(14), unedited(21), unedited(28)]), noneEarlier)
        // The first occurrence was deleted, the second edited: nothing is left before it either.
        XCTAssertEqual(neighbours(of: edited(7), among: [unedited(14), unedited(21), unedited(28)]), noneEarlier)
        XCTAssertEqual(neighbours(of: edited(14), among: []), alone)
    }

    func testSlotsDecideWhatIsEarlierNotTheShownTimes() {
        // The first occurrence moved past the second is still the first by slot.
        XCTAssertEqual(neighbours(of: edited(0, start: 10), among: [unedited(7)])?.earlierRemain, false)
        // An earlier slot moved later still counts as earlier, and an edited one counts at all.
        XCTAssertEqual(neighbours(of: edited(14), among: [edited(7, start: 20)])?.earlierRemain, true)
    }

    // MARK: - A scan is not the whole series

    func testAScanThatDoesNotCoverTheSeriesCannotShowNothingElseRemains() {
        XCTAssertEqual(neighbours(of: edited(0), among: [], covers: false), noneEarlier,
                       "nothing listed, but the scan stops short: the five-yearly series, measured")
        XCTAssertEqual(neighbours(of: edited(0), among: [], covers: true), alone)
    }

    func testAnOccurrenceTheScanDidNotListIsUnknown() {
        XCTAssertNil(DetachedOccurrenceSpan.neighbours(of: iCloudOccurrence, slot: Date(timeIntervalSinceReferenceDate: 0),
                                                       among: [unedited(7)], coversWholeSeries: true),
                     "it lies past the scan, so what is listed says nothing about what is around it")
    }

    func testOccurrencesNamedInTheSameCallDoNotCountAsLeft() {
        let other = edited(7)
        XCTAssertEqual(neighbours(of: edited(0), among: [other]), noneEarlier)
        XCTAssertEqual(neighbours(of: edited(0), among: [other], named: [other.eventIdentifier ?? ""]), alone,
                       "every remaining occurrence named by event_ids: each row does what the call asked")
        XCTAssertEqual(neighbours(of: edited(0), among: [other, unedited(14)], named: [other.eventIdentifier ?? ""]), noneEarlier)
        XCTAssertEqual(neighbours(of: edited(0), among: [other], covers: false, named: [other.eventIdentifier ?? ""]), noneEarlier)
    }

    // MARK: - Whether the scan covers the series (real rules, the real scan bounds)

    private let first = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// What `seriesOccurrences` lists up to, for a rule end the way it computes one.
    private func scannedTo(ruleEnd: Date?) -> Date {
        let window = UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: ruleEnd)
        return SeriesExceptionsPlanner.listingRanges(for: window).map(\.end).max() ?? window.end
    }

    private func covers(_ rule: EKRecurrenceRule, ruleEnd: Date? = nil) -> Bool {
        DetachedOccurrenceSpan.coversWholeSeries(rules: [.init(rule)], firstStart: first, scannedTo: scannedTo(ruleEnd: ruleEnd),
                                                 calendar: Calendar(identifier: .gregorian))
    }

    func testACountRuleThatFitsTheScanIsCovered() {
        XCTAssertTrue(covers(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5))))
        XCTAssertTrue(covers(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 100))))
    }

    /// The finding: every five years, twice. The second occurrence lies past the scan.
    func testTheFiveYearlySeriesIsNotCovered() {
        XCTAssertFalse(covers(EKRecurrenceRule(recurrenceWith: .yearly, interval: 5, end: EKRecurrenceEnd(occurrenceCount: 2))))
    }

    func testAnEndDateInsideTheScanIsCoveredAndOnePastItIsNot() {
        let day: TimeInterval = 86_400
        let near = first.addingTimeInterval(100 * day)
        XCTAssertTrue(covers(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(end: near)), ruleEnd: near))
        let far = first.addingTimeInterval(3000 * day)
        XCTAssertFalse(covers(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(end: far)), ruleEnd: far))
    }

    func testAnOpenRuleIsNotCovered() {
        XCTAssertFalse(covers(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)))
    }

    /// Monthly and yearly occurrences can skip (the 31st, February 29), so a count says nothing
    /// about how far they reach.
    func testACountRuleThatCanSkipIsNotCovered() {
        let calendar = Calendar(identifier: .gregorian)
        let monthly = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        let the15th = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!
        let the31st = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        XCTAssertNotNil(DetachedOccurrenceSpan.lastPossibleSlot(of: monthly, firstStart: the15th, calendar: calendar))
        XCTAssertNil(DetachedOccurrenceSpan.lastPossibleSlot(of: monthly, firstStart: the31st, calendar: calendar))
        let fifthFriday = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(
            recurrenceWith: .monthly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.friday, weekNumber: 5)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
            end: EKRecurrenceEnd(occurrenceCount: 3)))
        XCTAssertNil(DetachedOccurrenceSpan.lastPossibleSlot(of: fifthFriday, firstStart: the15th, calendar: calendar))
    }

    /// A daily or weekly rule filtered by month or day of the month has periods with no occurrence,
    /// so a count says nothing. Days of the week on a weekly rule are not a filter: every week holds
    /// one, and an ordinary weekly series reads back that way.
    func testAFilteredDailyOrWeeklyRuleIsNotCovered() {
        func rule(_ frequency: EKRecurrenceFrequency, days: [EKRecurrenceDayOfWeek]? = nil, months: [NSNumber]? = nil,
                  monthDays: [NSNumber]? = nil) -> EKRecurrenceRule {
            EKRecurrenceRule(recurrenceWith: frequency, interval: 1, daysOfTheWeek: days, daysOfTheMonth: monthDays,
                             monthsOfTheYear: months, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                             end: EKRecurrenceEnd(occurrenceCount: 100))
        }
        XCTAssertFalse(covers(rule(.weekly, months: [1])), "weekly, January only, 100 times: more than twenty years")
        XCTAssertFalse(covers(rule(.daily, monthDays: [1])))
        XCTAssertFalse(covers(rule(.daily, days: [EKRecurrenceDayOfWeek(.monday)])), "on a daily rule the days are a filter")
        XCTAssertTrue(covers(rule(.weekly, days: [EKRecurrenceDayOfWeek(.monday)])))
    }

    func testEveryRuleHasToFit() {
        let calendar = Calendar(identifier: .gregorian)
        let fits = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5)))
        let open = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        XCTAssertFalse(DetachedOccurrenceSpan.coversWholeSeries(rules: [fits, open], firstStart: first, scannedTo: scannedTo(ruleEnd: nil), calendar: calendar))
        XCTAssertFalse(DetachedOccurrenceSpan.coversWholeSeries(rules: [], firstStart: first, scannedTo: scannedTo(ruleEnd: nil), calendar: calendar),
                       "no rule read: nothing is shown")
    }

    /// A yearly rule on Feb 29 in the event's zone can show Feb 28 in another: the day is read where
    /// the rule runs, or a short count would pass the check and the rest of the series be missed.
    func testTheDayOfTheFirstOccurrenceIsReadInTheEventsZone() throws {
        let taipei = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2028-02-29T00:30:00+08:00"))
        let yearly = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        XCTAssertNil(DetachedOccurrenceSpan.lastPossibleSlot(of: yearly, firstStart: first, calendar: Calendar.gregorian(in: taipei)))
        XCTAssertNotNil(DetachedOccurrenceSpan.lastPossibleSlot(of: yearly, firstStart: first, calendar: Calendar.gregorian(in: try XCTUnwrap(TimeZone(identifier: "UTC")))),
                        "in another zone the same instant reads Feb 28")
    }

    // MARK: - update_event

    func testUpdateSpanAllIsRefusedOnlyWithAnEarlierOccurrenceLeft() {
        func refusal(_ id: String, _ isDetached: Bool, _ shape: DetachedOccurrenceSpan.Neighbours?) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: id, isDetached: isDetached, wholeSeries: true, neighbours: shape)
        }
        XCTAssertEqual(refusal(iCloudOccurrence, true, earlier), DetachedOccurrenceSpan.updateReason)
        XCTAssertEqual(refusal(iCloudOccurrence, false, earlier), DetachedOccurrenceSpan.updateReason, "the /RID= arm")
        XCTAssertEqual(refusal(otherSourceOccurrence, true, earlier), DetachedOccurrenceSpan.updateReason, "the isDetached arm")
        XCTAssertNil(refusal(iCloudOccurrence, true, noneEarlier), "the first occurrence, or the first left: every occurrence is updated (measured)")
        XCTAssertNil(refusal(series, false, earlier))
    }

    func testUnknownNeighboursAreRefusedWithTheirOwnText() {
        XCTAssertEqual(DetachedOccurrenceSpan.updateRefusal(identifier: otherSourceOccurrence, isDetached: true, wholeSeries: true, neighbours: nil),
                       DetachedOccurrenceSpan.unknownReason(suffix: "Nothing was written."))
        XCTAssertEqual(DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: otherSourceOccurrence, isDetached: true, batch: false, neighbours: nil),
                       DetachedOccurrenceSpan.unknownReason(suffix: "Nothing was deleted."))
        XCTAssertEqual(DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: otherSourceOccurrence, isDetached: true, batch: true, neighbours: nil),
                       DetachedOccurrenceSpan.unknownReason(suffix: "This row deleted nothing."))
    }

    /// With no `/RID=` the routes of the other texts loop, and neither "would split" nor "a recurring
    /// series" is known: it can be a one-off wrongly reported detached (#320: possible on Exchange
    /// only, Google measured reliable). `span this` works either way.
    func testTheUnknownTextClaimsNothingAndOffersWhatWorks() {
        let reason = DetachedOccurrenceSpan.unknownReason(suffix: "Nothing was written.")
        XCTAssertTrue(reason.contains("cannot be listed"), reason)
        XCTAssertTrue(reason.contains("span 'this'"), reason)
        XCTAssertTrue(reason.contains("a single event"), reason)
        for claim in ["would split", "would delete only", "list_events shows"] {
            XCTAssertFalse(reason.contains(claim), reason)
        }
    }

    func testSpanFutureAndSpanThisAreNotRefused() {
        XCTAssertNil(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, neighbours: earlier))
        XCTAssertNil(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, neighbours: nil))
    }

    // MARK: - Dates through an occurrence (PR #431 round 4)

    /// Measured on iCloud (2026-11-06): the other occurrences took the occurrence's own length with
    /// only `start_time`, its time with only `end_time`, its weekday with `all_day`. So every date
    /// write is refused on this path, in every position.
    func testDatesAreRefusedWithSpanAllWhereverTheOccurrenceIs() {
        func refusal(_ id: String, _ isDetached: Bool, _ shape: DetachedOccurrenceSpan.Neighbours?, changesDates: Bool = true) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: id, isDetached: isDetached, wholeSeries: true, changesDates: changesDates, neighbours: shape)
        }
        let reason = DetachedOccurrenceSpan.dateReason(wholeSeries: true)
        XCTAssertEqual(refusal(iCloudOccurrence, true, noneEarlier), reason, "the first occurrence, or the first left")
        XCTAssertEqual(refusal(iCloudOccurrence, true, earlier), reason, "updateReason's routes take no dates")
        XCTAssertEqual(refusal(iCloudOccurrence, false, noneEarlier), reason, "the /RID= arm")
        XCTAssertEqual(refusal(otherSourceOccurrence, true, noneEarlier), reason, "the isDetached arm")
        XCTAssertEqual(refusal(otherSourceOccurrence, true, nil), DetachedOccurrenceSpan.unknownReason(suffix: "Nothing was written."),
                       "nothing known: the text that claims nothing")
        XCTAssertNil(refusal(series, false, noneEarlier), "the series' own id is not this path")
        XCTAssertNil(refusal(series, false, earlier))
        XCTAssertNil(refusal(iCloudOccurrence, true, noneEarlier, changesDates: false), "other fields go through")
    }

    func testDatesAreRefusedWithSpanFutureAndNotWithSpanThis() {
        var scans = 0
        let scan = { () -> DetachedOccurrenceSpan.Neighbours? in scans += 1; return nil }
        func refusal(_ id: String, _ isDetached: Bool, future: Bool, changesDates: Bool) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: id, isDetached: isDetached, wholeSeries: false, futureSpan: future,
                                                 changesDates: changesDates, neighbours: scan())
        }
        XCTAssertEqual(refusal(iCloudOccurrence, true, future: true, changesDates: true), DetachedOccurrenceSpan.dateReason(wholeSeries: false))
        XCTAssertEqual(refusal(iCloudOccurrence, false, future: true, changesDates: true), DetachedOccurrenceSpan.dateReason(wholeSeries: false), "the /RID= arm")
        XCTAssertEqual(refusal(otherSourceOccurrence, true, future: true, changesDates: true), DetachedOccurrenceSpan.dateReason(wholeSeries: false), "the isDetached arm")
        XCTAssertNil(refusal(iCloudOccurrence, true, future: true, changesDates: false), "other fields go through")
        XCTAssertNil(refusal(iCloudOccurrence, true, future: false, changesDates: true), "span this")
        XCTAssertNil(refusal(series, false, future: true, changesDates: true), "the series' own id is not this path")
        XCTAssertEqual(scans, 0, "span future needs no scan")
    }

    func testTheDateRefusalForSpanAllNamesWhatWasRunOnADevice() {
        let reason = DetachedOccurrenceSpan.dateReason(wholeSeries: true)
        for phrase in ["span 'all' through it cannot change start_time, end_time, all_day or timezone",
                       "the other occurrences would take this occurrence's own time, length or day",
                       "To change start_time, end_time or timezone for the whole series, use the id list_events shows for an occurrence that was not edited on its own, with span 'all'.",
                       "If that is refused, or for all_day (through that id it brings an edited occurrence's original slot back as an extra occurrence), no single call changes the whole series: use span 'this' on each occurrence, with occurrence_date when the id list_events shows for it has no /RID=… part."] {
            XCTAssertTrue(reason.contains(phrase), reason)
        }
        XCTAssertFalse(reason.contains("span 'future'"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    /// No route was measured for span `future`, so none is offered beyond the one occurrence.
    func testTheDateRefusalForSpanFutureSaysItIsNotSupported() {
        let reason = DetachedOccurrenceSpan.dateReason(wholeSeries: false)
        for phrase in ["span 'future' through it cannot change start_time, end_time, all_day or timezone",
                       "the later occurrences would take this occurrence's own time, length or day",
                       "This is not supported from an occurrence edited on its own.",
                       "To change this occurrence alone, use span 'this'."] {
            XCTAssertTrue(reason.contains(phrase), reason)
        }
        XCTAssertFalse(reason.contains("span 'all'"), reason)
        XCTAssertFalse(reason.contains("list_events"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    func testTheNeighboursAreNotScannedUnlessTheAnswerDependsOnThem() {
        var scans = 0
        let scan = { () -> DetachedOccurrenceSpan.Neighbours? in scans += 1; return nil }
        _ = DetachedOccurrenceSpan.updateRefusal(identifier: series, isDetached: false, wholeSeries: true, neighbours: scan())
        _ = DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, neighbours: scan())
        _ = DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: series, isDetached: false, batch: false, neighbours: scan())
        XCTAssertEqual(scans, 0)
        _ = DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, neighbours: scan())
        XCTAssertEqual(scans, 1)
    }

    // MARK: - Series-level changes through an occurrence

    /// `clear_recurrence` answered updated and changed nothing (measured), and a calendar of another
    /// account was not measured. A new `recurrence` is not here: it worked with span `all` from the
    /// first occurrence and from the first left, and with span `future` from a middle one (measured).
    func testOnlyWhatDidNotWorkOrWasNotMeasuredIsRefusedThroughAnOccurrence() {
        func refused(id: String = "CAL-1:SERIES-1/RID=826768800", detached: Bool = true, all: Bool = false, span: EKSpan = .futureEvents,
                     account: Bool = false, clears: Bool = false) -> Bool {
            DetachedOccurrenceSpan.refusesSeriesProperty(identifier: id, isDetached: detached, wholeSeries: all, span: span,
                                                         changesAccount: account, clearsRecurrence: clears)
        }
        XCTAssertTrue(refused(clears: true))
        XCTAssertTrue(refused(account: true))
        XCTAssertTrue(refused(all: true, clears: true))
        XCTAssertFalse(refused(), "a new recurrence or any other field")
        XCTAssertFalse(refused(span: .thisEvent, clears: true), "span this is not refused here; what it gets wrong is in #426")
        XCTAssertFalse(refused(id: series, detached: false, all: true, clears: true), "the series' own id")
    }

    // MARK: - occurrence_date through an occurrence's own id

    func testAnOccurrenceDateThatIsNotThisOccurrenceIsRefused() {
        func refused(id: String = "CAL-1:SERIES-1/RID=826768800", detached: Bool = true, all: Bool = false, date: Bool = true, matches: Bool) -> Bool {
            DetachedOccurrenceSpan.refusesOccurrenceDate(identifier: id, isDetached: detached, wholeSeries: all, hasOccurrenceDate: date, matches: matches)
        }
        XCTAssertTrue(refused(matches: false))
        XCTAssertTrue(refused(id: otherSourceOccurrence, matches: false))
        XCTAssertFalse(refused(matches: true))
        XCTAssertFalse(refused(date: false, matches: false))
        XCTAssertFalse(refused(all: true, matches: false), "span all takes no occurrence")
        XCTAssertFalse(refused(id: series, detached: false, matches: false), "a one-off: not this check")
    }

    // MARK: - Messages

    /// Literal text on purpose: the route is the content, so it is not compared with the constant
    /// it was built from. Each route was run on a device (iCloud, 2026-11-05): the first occurrence's
    /// id with span all updates every occurrence, or is refused when a first occurrence was deleted
    /// and the first left is unedited (#326); the series' id with span all deletes, and an edited
    /// first occurrence's id with span future deletes. The series' identifier is not the route:
    /// #428 refuses it when the first occurrence was edited, and the series' id plus the edited
    /// occurrence's date does not reach that occurrence.
    private let routeToTheFirst = "the id list_events shows for the occurrence that comes first in the series (by its original date, not a time it was moved to)"

    func testTheUpdateRefusalSaysWhatWouldHappenAndNamesRoutesThatWork() {
        let reason = DetachedOccurrenceSpan.updateReason
        XCTAssertTrue(reason.contains("span 'all' through it would split the series here"), reason)
        XCTAssertTrue(reason.contains("the earlier occurrences would stay in the old series"), reason)
        XCTAssertTrue(reason.contains("To update the whole series, use \(routeToTheFirst) with span 'all'."), reason)
        XCTAssertTrue(reason.contains("A series whose first occurrence was deleted"), reason)
        XCTAssertTrue(reason.contains("a whole-series update is not supported (#326)"), reason)
        XCTAssertTrue(reason.contains("To update from this occurrence on, use span 'future'"), reason)
        XCTAssertTrue(reason.contains("To edit one occurrence, use span 'this'."), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
        XCTAssertFalse(reason.contains("occurrence_date"), reason)
    }

    func testTheDeleteRefusalSaysWhatWouldHappenAndNamesRoutesThatWork() {
        for (reason, suffix) in [(DetachedOccurrenceSpan.seriesDeleteReason, "Nothing was deleted."),
                                 (DetachedOccurrenceSpan.seriesDeleteBatchReason, "This row deleted nothing.")] {
            XCTAssertTrue(reason.contains("would delete only this occurrence, not the series"), reason)
            XCTAssertTrue(reason.contains("To delete the whole series, use \(routeToTheFirst), with span 'all' when that id has no /RID=… part and span 'future' when it has one"), reason)
            XCTAssertTrue(reason.contains("cannot be undone"), "the span future route gives undo up: \(reason)")
            XCTAssertTrue(reason.contains("To delete this occurrence only, use span 'this'."), reason)
            XCTAssertTrue(reason.hasSuffix(suffix), reason)
        }
        XCTAssertTrue(DetachedOccurrenceSpan.seriesDeleteReason.hasPrefix("event_id names"))
        XCTAssertFalse(DetachedOccurrenceSpan.seriesDeleteBatchReason.contains("event_id "), "the batch names event_ids")
        XCTAssertFalse(DetachedOccurrenceSpan.seriesDeleteBatchReason.contains("Nothing was deleted"), "the batch's other rows may have been")
    }

    func testNoReasonSendsTheCallerToTheSeriesIdentifier() {
        for reason in [DetachedOccurrenceSpan.updateReason, DetachedOccurrenceSpan.seriesDeleteReason, DetachedOccurrenceSpan.seriesDeleteBatchReason] {
            XCTAssertFalse(reason.contains("series' identifier"), reason)
            XCTAssertFalse(reason.contains("without its /RID"), reason)
        }
    }

    func testTheSeriesPropertyRefusalForSpanAllOffersAnUneditedOccurrence() {
        let reason = DetachedOccurrenceSpan.seriesPropertyReason(wholeSeries: true)
        for phrase in ["cannot take clear_recurrence or a calendar of another account",
                       "clear_recurrence through it would answer updated and change nothing",
                       "use the id list_events shows for an occurrence that was not edited on its own, with span 'all'",
                       "if that is refused too, the change is not supported on this series"] {
            XCTAssertTrue(reason.contains(phrase), reason)
        }
        XCTAssertFalse(reason.contains("recurrence, clear_recurrence"), "a new recurrence goes through: \(reason)")
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    /// Span `all` would reach earlier occurrences the caller did not ask for, and it cannot be
    /// undone: span `future` gets no route.
    func testTheSeriesPropertyRefusalForSpanFutureOffersNoRoute() {
        let reason = DetachedOccurrenceSpan.seriesPropertyReason(wholeSeries: false)
        XCTAssertTrue(reason.contains("span 'future' through it cannot take clear_recurrence or a calendar of another account"), reason)
        XCTAssertTrue(reason.contains("Neither is supported from an occurrence edited on its own."), reason)
        XCTAssertFalse(reason.contains("span 'all'"), reason)
        XCTAssertFalse(reason.contains("list_events"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    func testTheOccurrenceDateRefusalNamesBothWays() {
        let reason = DetachedOccurrenceSpan.occurrenceDateReason
        XCTAssertTrue(reason.contains("occurrence_date is another day"), reason)
        XCTAssertTrue(reason.contains("use the id list_events shows for that occurrence, with its occurrence_date"), reason)
        XCTAssertTrue(reason.contains("leave occurrence_date out"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was changed."), reason)
    }

    // MARK: - event_ids row order

    /// An occurrence's own row runs before the series' row, earliest first, so that the result does
    /// not depend on a Set's order: with the series' row first and the first occurrence edited, the
    /// series' row was refused and the occurrence's row then deleted it alone (measured).
    func testOccurrenceRowsComeFirstEarliestFirstAndEachIdOnce() {
        XCTAssertEqual(DetachedOccurrenceSpan.occurrenceRowsFirst(["S", "S/RID=30", "T", "S/RID=4", "S"]),
                       ["S/RID=4", "S/RID=30", "S", "T"])
        XCTAssertEqual(DetachedOccurrenceSpan.occurrenceRowsFirst(["T", "S"]), ["T", "S"], "the caller's order otherwise")
    }

    /// #416 measured that the occurrence which comes first reaches the series through its own id,
    /// so the hint for a bare id says so, in words a batch caller can use too.
    func testTheEditedBeforeHintsNameTheOwnIdRoute() {
        for text in [EventKitManager.standInEditedBeforeReason, EventKitManager.standInEditedBeforeBatchReason] {
            XCTAssertTrue(text.contains("The occurrence that comes first in the series reaches it through its own id: update_event with span 'all', delete_event with span 'future' (which cannot be undone)."), text)
        }
    }

    func testTheRefusalSurfacesItsReasonVerbatim() {
        let reason = DetachedOccurrenceSpan.seriesDeleteReason
        let error = EventKitError.occurrenceAddressRefused(reason: reason)
        XCTAssertEqual(error.errorDescription, reason)
        XCTAssertEqual(EventKitErrorSanitizer.sanitizeForResponse(error).code, reason,
                       "a fixed text, so it reaches the caller as written")
    }


    // MARK: - Wiring (source pins: the writes cannot be driven without EventKit access)

    private func collapsed(_ declaration: String, upTo end: String, in file: String) throws -> String {
        let source = SourceScan.strippingComments(try SourcePins.source(file))
        let body = try XCTUnwrap(SourcePins.body(of: declaration, in: source), declaration)
        let until = try XCTUnwrap(body.range(of: end), "\(declaration) … \(end)")
        return SourceScan.collapsingWhitespace(String(body[..<until.lowerBound]))
    }

    private func updateBody() throws -> String {
        let source = SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift"))
        let start = try XCTUnwrap(source.range(of: "func updateEvent("))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "if let t = title { event.title = t }"))
        return SourceScan.collapsingWhitespace(String(rest[..<end.lowerBound]))
    }

    func testUpdateEventChecksBeforeItTakesTheSnapshotOrWrites() throws {
        let head = try collapsed("func updateEvent(", upTo: "let oldSnapshot = EventSnapshot(from: masterEvent)", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(head.contains("if let refusal = DetachedOccurrenceSpan.updateRefusal( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, futureSpan: span == .futureEvents, changesDates: startDate != nil || endDate != nil || isAllDay != nil || timezone != nil || clearTimezone, neighbours: occurrenceNeighbours(of: masterEvent, id: identifier)) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), head)
    }

    /// Before the first field is assigned, as #373 requires of every refusal.
    func testTheOtherRefusalsOfAnUpdateComeBeforeTheFirstAssignment() throws {
        let body = try updateBody()
        XCTAssertTrue(body.contains("if DetachedOccurrenceSpan.refusesSeriesProperty( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, span: span, changesAccount: crossesAccounts, clearsRecurrence: clearRecurrence) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.seriesPropertyReason(wholeSeries: applyToAll)) }"), body)
        XCTAssertTrue(body.contains("DetachedOccurrenceSpan.refusesOccurrenceDate( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, hasOccurrenceDate: occurrenceDate != nil, matches: occurrenceDateMatches(occurrenceDate, occurrence: masterEvent, id: identifier))"), body)
    }

    /// A start or a timezone cannot reach the weekday check through an occurrence's id with span
    /// `all` or `future`, as the dates are refused first, so the check reads the event as it did.
    func testTheWeekdayCheckReadsTheEventsOwnRules() throws {
        let body = try updateBody()
        XCTAssertTrue(body.contains("let rules = event.recurrenceRules,"), body)
        XCTAssertFalse(body.contains("seriesObject"), body)
    }

    func testDeleteEventChecksTheOccurrenceDateBeforeItRemoves() throws {
        let head = try collapsed("func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(head.contains("if DetachedOccurrenceSpan.refusesOccurrenceDate( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: false, hasOccurrenceDate: occurrenceDate != nil, matches: occurrenceDateMatches(occurrenceDate, occurrence: masterEvent, id: identifier)) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.occurrenceDateReason) }"), head)
    }

    /// The slot and the completeness that `neighbours` judges come from the scan's own bounds.
    func testTheNeighboursUseTheSlotAndTheBoundsOfTheScan() throws {
        let source = SourceScan.strippingComments(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let start = try XCTUnwrap(source.range(of: "func occurrenceNeighbours("))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "func seriesDeleteRefusal("))
        let body = SourceScan.collapsingWhitespace(String(rest[..<end.lowerBound]))
        XCTAssertTrue(body.contains("UndoPostState.originalSlot(eventIdentifier: id, externalIdentifier: occurrence.calendarItemExternalIdentifier, occurrenceDate: occurrence.occurrenceDate)"), body)
        XCTAssertTrue(body.contains("SeriesExceptionsPlanner.listingRanges(for: window).map(\\.end).max()"), body)
        XCTAssertTrue(body.contains("coversWholeSeries: DetachedOccurrenceSpan.coversWholeSeries( rules: (series.recurrenceRules ?? []).map(DetachedOccurrenceSpan.RuleExtent.init), firstStart: firstStart, scannedTo: scannedTo, calendar: Calendar.gregorian(in: series.timeZone ?? .current))"), body)
    }

    /// Covered on a device only until round 3: each would fail silently.
    func testTheRoundTwoWiringIsPinned() throws {
        let manager = try updateBody()
        XCTAssertTrue(manager.contains("if occurrenceDate != nil, !applyToAll, DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: masterEvent.isDetached) { matchedOccurrence = MatchedOccurrence(start: masterEvent.startDate, zone: Self.occurrenceZone(of: masterEvent)) }"), manager)
        let source = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")))
        XCTAssertTrue(source.contains("return [occurrence.startDate, slot].contains {"), "the shown day or the original one")
        XCTAssertTrue(source.contains("neighbours: occurrenceNeighbours(of: event, id: id, namedInTheCall: namedInTheCall))"))
        XCTAssertTrue(source.contains("namedInTheCall: namedInTheCall)"))
    }

    func testTheEventIdsRowsRunThroughTheOrdering() throws {
        let source = SourceScan.strippingComments(try SourcePins.source("Server.swift"))
        XCTAssertTrue(source.contains("let uniqueIds = DetachedOccurrenceSpan.occurrenceRowsFirst(items.map(\\.identifier))"))
    }

    func testTheSeriesDeletesCheckBeforeTheyRemove() throws {
        let single = try collapsed("func deleteEventSeries(identifier: String)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(single.contains("if let refusal = seriesDeleteRefusal(event, id: identifier) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), single)
        let batch = try collapsed("func deleteEventSeriesBatch(identifiers: [String], refusingOccurrenceIdentifiers: Bool)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(batch.contains("if refusingOccurrenceIdentifiers, let refusal = seriesDeleteRefusal(event, id: id, namedInTheCall: Set(identifiers), batch: true) { failures.append((id, refusal)) continue }"), batch)
    }

    /// The preview by `event_ids` walks the rows as the real call does and does not list what the
    /// real call refuses, for span all only. `DeleteEventsBatchHandlerTests` compares the answers;
    /// the manager's side reads the store, so it is pinned here.
    func testTheDryRunByEventIdsUsesTheRefusal() throws {
        let server = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("Server.swift")))
        XCTAssertTrue(server.contains("let rows = spanAll ? DetachedOccurrenceSpan.occurrenceRowsFirst(eventIds) : eventIds"), "the real call's order")
        XCTAssertTrue(server.contains("identifier: id, spanAll: spanAll, namedInTheCall: named, goneInTheCall: gone"))
        let source = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventBatchDeletionSource.swift")))
        XCTAssertTrue(source.contains("guard let event = freshEventWithOrigin(id: identifier, goneInTheCall: goneInTheCall)?.event else { throw notFoundError(id: identifier) }"), source)
        XCTAssertTrue(source.contains("if spanAll, let refusal = seriesDeleteRefusal(event, id: identifier, namedInTheCall: namedInTheCall, batch: true) { return .refused(refusal) }"), source)
        let scan = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")))
        XCTAssertTrue(scan.contains("FirstRemainingOccurrence.pick(candidates, identifier: id, refuseWhenEditedBefore: refuseWhenEditedBefore, goneInTheCall: goneInTheCall)"), scan)
    }
}
