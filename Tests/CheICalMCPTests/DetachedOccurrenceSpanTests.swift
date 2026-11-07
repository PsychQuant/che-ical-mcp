import CoreLocation
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
/// through such an identifier does what the span says for the fields it allows, and both spans
/// allow a closed list (PR #431 round 5). These are the coordinator's defaults while the maintainer
/// has not answered.
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
                       DetachedOccurrenceSpan.unknownReason(identifier: otherSourceOccurrence, span: "'all'", suffix: "Nothing was written."))
        XCTAssertEqual(DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: otherSourceOccurrence, isDetached: true, batch: false, neighbours: nil),
                       DetachedOccurrenceSpan.unknownReason(identifier: otherSourceOccurrence, span: "'all'", suffix: "Nothing was deleted."))
        XCTAssertEqual(DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: otherSourceOccurrence, isDetached: true, batch: true, neighbours: nil),
                       DetachedOccurrenceSpan.unknownReason(identifier: otherSourceOccurrence, span: "'all'", suffix: "This row deleted nothing."))
    }

    /// With no `/RID=` the routes of the other texts loop, and neither "would split" nor "a recurring
    /// series" is known: it can be a one-off wrongly reported detached (#320: possible on Exchange
    /// only, Google measured reliable). `span this` works either way.
    func testTheUnknownTextClaimsNothingAndOffersWhatWorks() {
        let reason = DetachedOccurrenceSpan.unknownReason(identifier: otherSourceOccurrence, span: "'all'", suffix: "Nothing was written.")
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

    /// A series past the scan is ordinary: a weekly meeting started six years ago, with this week's
    /// occurrence edited. With a `/RID=` the series' id is known, and it was run there (2026-11-06):
    /// update and delete with span `all`. The neutral text stays for a source with no `/RID=`.
    func testAnOccurrencePastTheScanGetsTheSeriesIdRoute() {
        for (suffix, text) in [("Nothing was written.", DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, neighbours: nil)),
                               ("Nothing was deleted.", DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: iCloudOccurrence, isDetached: true, batch: false, neighbours: nil)),
                               ("This row deleted nothing.", DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: iCloudOccurrence, isDetached: true, batch: true, neighbours: nil))] {
            let reason = text ?? ""
            for phrase in ["names one occurrence of a recurring series, edited on its own",
                           "past what can be listed of the series, about five years from its start"] {
                XCTAssertTrue(reason.contains(phrase), reason)
            }
            XCTAssertTrue(reason.hasSuffix(suffix), reason)
            if suffix == "Nothing was written." {
                XCTAssertTrue(reason.contains("Use the id list_events shows for an occurrence that was not edited on its own, with span 'all', for the whole series."), reason)
                XCTAssertTrue(reason.contains("If that is refused, this shape has no tested way yet."), reason)
            } else {
                XCTAssertTrue(reason.contains("To delete the whole series, use"), reason)
                XCTAssertFalse(reason.contains("occurrence_date"), "a batch row cannot take one, and the delete has a way: \(reason)")
            }
        }
    }

    /// A one-off a source reports as detached must not be told it is a series, with span `future`
    /// either: nothing else is known without a listing.
    func testSpanFutureWithNothingKnownGetsTheNeutralText() {
        let reason = DetachedOccurrenceSpan.updateRefusal(identifier: otherSourceOccurrence, isDetached: true, wholeSeries: false, futureSpan: true,
                                                          fields: ["title"], neighbours: nil)
        XCTAssertEqual(reason, DetachedOccurrenceSpan.unknownReason(identifier: otherSourceOccurrence, span: "'future'", suffix: "Nothing was written."))
        XCTAssertFalse(reason?.contains("of a recurring series") ?? true, reason ?? "")
        XCTAssertTrue(reason?.contains("span 'this'") ?? false, reason ?? "")
    }

    // MARK: - The closed list of fields through an occurrence (PR #431 round 5)

    /// Every key `update_event` has: the schema's, and those the handler reads that the schema does
    /// not list (`url`). A key added to either fails here until it is put in one of the lists, and
    /// until then the code refuses it, so a new field is never let through unmeasured.
    private let refusedKeys: Set<String> = ["clear_timezone", "calendar_name", "calendar_source", "clear_recurrence"]
    private let ownTimeKeys = DetachedOccurrenceSpan.seriesTimeUpdateFields

    func testEveryKeyOfUpdateEventIsClassified() throws {
        let schema = try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == "update_event" }?.inputSchema.objectValue)
        var keys = Set(try XCTUnwrap(schema["properties"]?.objectValue).keys)
        let source = SourceScan.strippingComments(try SourcePins.source("Server.swift"))
        let from = try XCTUnwrap(source.range(of: "private func handleUpdateEvent(arguments: [String: Value]) async throws -> String {"))
        let to = try XCTUnwrap(source.range(of: "private func ", range: from.upperBound..<source.endIndex))
        let handler = String(source[from.upperBound..<to.lowerBound])
        let literal = try NSRegularExpression(pattern: #"(?:arguments\["|key: ")([a-z_]+)""#)
        for match in literal.matches(in: handler, range: NSRange(handler.startIndex..., in: handler)) {
            keys.insert(try XCTUnwrap(Range(match.range(at: 1), in: handler).map { String(handler[$0]) }))
        }
        let allowed = DetachedOccurrenceSpan.allowedUpdateFields
        let unrelated = DetachedOccurrenceSpan.updateKeysThatWriteNothing
        XCTAssertTrue(keys.contains("url"), "the handler's own keys are read")
        XCTAssertEqual(keys.subtracting(allowed).subtracting(ownTimeKeys).subtracting(unrelated).subtracting(refusedKeys), [], "classify these")
        XCTAssertEqual(allowed, ["title", "notes", "location", "recurrence"])
        XCTAssertEqual(ownTimeKeys, ["start_time", "end_time", "all_day", "timezone", "url", "alarms_minutes_offsets", "structured_location"])
        XCTAssertEqual(unrelated, ["event_id", "span", "occurrence_date"])
        for (one, other) in [(allowed, refusedKeys), (unrelated, refusedKeys), (ownTimeKeys, refusedKeys), (ownTimeKeys, allowed), (ownTimeKeys, unrelated)] {
            XCTAssertTrue(one.isDisjoint(with: other))
        }
        for key in ownTimeKeys {
            XCTAssertEqual(DetachedOccurrenceSpan.refusedUpdateFields([key, "event_id", "span"], shape: measured(), datesStayOnTheDay: true), [], key)
        }
        XCTAssertEqual(DetachedOccurrenceSpan.refusedUpdateFields(keys), refusedKeys.union(ownTimeKeys).intersection(keys))
        XCTAssertEqual(DetachedOccurrenceSpan.refusedUpdateFields(keys, shape: measured()), refusedKeys.union(ownTimeKeys).intersection(keys),
                       "all at once is no measured row")
    }

    func testAKeyNobodyClassifiedIsRefused() {
        XCTAssertEqual(DetachedOccurrenceSpan.refusedUpdateFields(["event_id", "title", "new_field"], shape: measured()), ["new_field"])
        XCTAssertEqual(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true,
                                                            fields: ["event_id", "new_field"], neighbours: measured()),
                       DetachedOccurrenceSpan.fieldsReason(wholeSeries: true))
    }

    /// The shape #428 measured: a timed weekly series with an end, the occurrence edited only in
    /// title, notes, location or alarms, no other edited occurrence.
    private func measured(earlierRemain: Bool = false, own: DetachedOccurrenceSpan.OwnValues = .init(),
                          facts: DetachedOccurrenceSpan.SeriesTimeFacts = .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: true)) -> DetachedOccurrenceSpan.Neighbours {
        var shape = DetachedOccurrenceSpan.Neighbours(earlierRemain: earlierRemain, othersRemain: true, own: own)
        shape.seriesTime = facts
        return shape
    }

    func testOnlyTheListedFieldsGoThroughWithSpanAll() {
        func refusal(_ id: String, _ isDetached: Bool, _ shape: DetachedOccurrenceSpan.Neighbours?, _ fields: Set<String>) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: id, isDetached: isDetached, wholeSeries: true, fields: fields, neighbours: shape)
        }
        let reason = DetachedOccurrenceSpan.fieldsReason(wholeSeries: true)
        // verify r5: `noneEarlier` knows nothing of the first slot, so its text leaves out recurrence.
        let unknownFirst = DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: true)
        for key in refusedKeys {
            XCTAssertEqual(refusal(iCloudOccurrence, true, measured(), ["event_id", "span", key]), reason, key)
            XCTAssertEqual(refusal(iCloudOccurrence, true, noneEarlier, ["event_id", "span", key]), unknownFirst, key)
            XCTAssertEqual(refusal(iCloudOccurrence, true, earlier, [key]), DetachedOccurrenceSpan.updateReason, "verify r6: the split is answered first (\(key))")
            XCTAssertNil(refusal(series, false, noneEarlier, [key]), "the series' own id is not this path")
        }
        XCTAssertEqual(refusal(iCloudOccurrence, false, measured(), ["calendar_name"]), reason, "the /RID= arm")
        XCTAssertEqual(refusal(otherSourceOccurrence, true, measured(), ["calendar_name"]), reason, "the isDetached arm")
        XCTAssertNil(refusal(iCloudOccurrence, true, measured(), ["event_id", "span", "title", "notes", "location", "recurrence"]),
                     "verify r4: a rule needs the series' first slot to be known there")
        XCTAssertEqual(refusal(iCloudOccurrence, true, noneEarlier, ["recurrence"]), DetachedOccurrenceSpan.firstLeftRecurrenceReason, "nothing known: the side that refuses")
    }

    func testOnlyTheListedFieldsGoThroughWithSpanFutureAndSpanThisIsNotThisPath() {
        func refusal(future: Bool, _ fields: Set<String>) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, futureSpan: future,
                                                 fields: fields, neighbours: earlier)
        }
        for key in refusedKeys {
            XCTAssertEqual(refusal(future: true, [key]), DetachedOccurrenceSpan.fieldsReason(wholeSeries: false), key)
            XCTAssertNil(refusal(future: false, [key]), "span this: \(key)")
        }
        XCTAssertNil(refusal(future: true, ["title", "notes", "location", "recurrence"]))
    }

    // MARK: - While the occurrence has the series' time, length and day (#428)

    private func dateRefusal(_ fields: Set<String>, whole: Bool = true, sameDay: Bool = true, _ shape: DetachedOccurrenceSpan.Neighbours?) -> String? {
        DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: whole, futureSpan: !whole,
                                             fields: fields, datesStayOnTheDay: sameDay, neighbours: shape)
    }

    // MARK: - verify r2

    /// verify r2 (MEDIUM): a later occurrence, span future, as the listing gives it: an earlier
    /// occurrence left and its own slot not the series' first, while the series' first slot is
    /// there. timezone, url and structured_location were measured clean there.
    func testALaterOccurrenceWithSpanFutureTakesTheFirstRowFields() throws {
        let first = Date(timeIntervalSinceReferenceDate: 0)
        let third = edited(14)
        let listing = [unedited(0), unedited(7), third, unedited(21), unedited(28)]
        let own = UndoPostState.ownValues(one: UndoSnapshotFixtures.event(title: "Own", startDate: try XCTUnwrap(third.slot)),
                                          slot: try XCTUnwrap(third.slot), firstStart: first,
                                          series: UndoSnapshotFixtures.event(title: "Series", startDate: Date(timeIntervalSinceReferenceDate: 7 * day)))
        XCTAssertTrue(own.firstSlotGone, "this occurrence's slot is not the first: that is what the flag says")
        var shape = try XCTUnwrap(DetachedOccurrenceSpan.neighbours(of: third.eventIdentifier ?? "", slot: try XCTUnwrap(third.slot),
                                                                   among: listing, coversWholeSeries: true, own: own))
        shape.seriesTime = DetachedOccurrenceSpan.seriesTimeFacts(of: third.eventIdentifier ?? "", among: listing, coversWholeSeries: true,
                                                                  measuredRule: true, countBounded: true, firstStart: first,
                                                                  now: first.addingTimeInterval(-day))
        XCTAssertTrue(shape.earlierRemain)
        XCTAssertTrue(shape.seriesTime.firstSlotPresent)
        for key in DetachedOccurrenceSpan.seriesTimeFieldsOfTheFirstRows {
            XCTAssertNil(dateRefusal([key], whole: false, shape), key)
        }
        // The first deleted: the earliest listed slot is not the series' first start.
        let left = Array(listing.dropFirst())
        XCTAssertFalse(DetachedOccurrenceSpan.seriesTimeFacts(of: third.eventIdentifier ?? "", among: left, coversWholeSeries: true,
                                                              measuredRule: true, countBounded: true, firstStart: first).firstSlotPresent)
        var gone = shape
        gone.seriesTime.firstSlotPresent = false
        for key in DetachedOccurrenceSpan.seriesTimeFieldsOfTheFirstRows {
            XCTAssertEqual(dateRefusal([key], whole: false, gone), DetachedOccurrenceSpan.fieldsReason(wholeSeries: false), key)
        }
    }

    /// verify r2 (MEDIUM): every measured start_time and end_time row moved the time on the same
    /// day. Another day, or another weekday, was not run, and is refused.
    func testADateOnAnotherDayIsRefused() {
        for fields: Set<String> in [["start_time"], ["end_time"], ["start_time", "end_time"]] {
            XCTAssertNil(dateRefusal(fields, sameDay: true, measured()), "\(fields)")
            XCTAssertEqual(dateRefusal(fields, sameDay: false, measured()), DetachedOccurrenceSpan.fieldsReason(wholeSeries: true), "\(fields)")
            XCTAssertEqual(dateRefusal(fields, whole: false, sameDay: false, measured()), DetachedOccurrenceSpan.fieldsReason(wholeSeries: false), "\(fields)")
        }
        XCTAssertNil(dateRefusal(["url"], sameDay: false, measured()), "no date written: the day does not matter")
        XCTAssertNil(dateRefusal(["all_day"], sameDay: false, measured()))
    }

    func testTheDayIsReadInTheEventsZone() throws {
        let taipei = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-12-07T02:00:00Z")), end = try XCTUnwrap(iso.date(from: "2026-12-07T03:00:00Z")) // Mon 10-11
        func stays(_ newStart: String?, _ newEnd: String?, zone: TimeZone? = nil) -> Bool {
            DetachedOccurrenceSpan.datesStayOnTheDay(newStart: newStart.flatMap(iso.date(from:)), newEnd: newEnd.flatMap(iso.date(from:)),
                                                     start: start, end: end, zone: zone ?? taipei)
        }
        XCTAssertTrue(stays(nil, nil))
        XCTAssertTrue(stays("2026-12-07T01:00:00Z", nil), "09:00 the same day")
        XCTAssertTrue(stays(nil, "2026-12-07T04:00:00Z"), "end 12:00")
        XCTAssertTrue(stays("2026-12-07T01:00:00Z", "2026-12-07T02:00:00Z"))
        XCTAssertFalse(stays("2026-12-08T02:00:00Z", nil), "a day later")
        XCTAssertFalse(stays("2026-12-14T02:00:00Z", nil), "a week later, the same weekday")
        XCTAssertFalse(stays(nil, "2026-12-08T04:00:00Z"), "an end on the next day")
        XCTAssertFalse(stays("2026-12-07T15:30:00Z", nil), "23:30 keeps the hour of length: its end falls on the next day")
        XCTAssertTrue(stays("2026-12-06T17:00:00Z", nil), "01:00 Monday in Taipei: the same day there")
        XCTAssertFalse(stays("2026-12-06T17:00:00Z", nil, zone: try XCTUnwrap(TimeZone(identifier: "UTC"))), "read in UTC it is Sunday")
    }

    /// verify r2 (LOW): the shape where every remaining occurrence was edited is not taken, and
    /// only a `/RID=` identifier under this series counts.
    func testTheEarliestEditedNeedsTheMeasuredIdShape() {
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited([edited(0, id: "\(series)/OTHER=1"), unedited(7)], identifier: series),
                     "'/' without RID= was not measured")
    }

    /// verify r2 (LOW): reached through the series' id, the refusal says so and names no route
    /// back to the series' id.
    func testARefusalReachedThroughTheSeriesIdSaysSo() {
        let reasons = [DetachedOccurrenceSpan.fieldsReason(wholeSeries: true), DetachedOccurrenceSpan.sameValueReason(wholeSeries: true),
                       DetachedOccurrenceSpan.carriedReason(wholeSeries: true), DetachedOccurrenceSpan.recurrenceDayReason,
                       DetachedOccurrenceSpan.unknownReason(identifier: iCloudOccurrence, span: "'all'", suffix: "Nothing was written."),
                       "something else"]
        for reason in reasons {
            let text = DetachedOccurrenceSpan.throughSeriesID(reason)
            XCTAssertTrue(text.hasPrefix("event_id is the series' identifier, and the occurrence that comes first in this series was edited on its own, so update_event with span 'all' went through that occurrence"), text)
            XCTAssertTrue(text.contains("Single occurrences take span 'this' with occurrence_date;"), text)
            // verify r3: with every remaining occurrence edited the series' id reaches none of them
            // with occurrence_date (#335 item 1), so the text names their own ids instead.
            let allEdited = DetachedOccurrenceSpan.throughSeriesID(reason, allEdited: true)
            XCTAssertFalse(allEdited.contains("occurrence_date"), allEdited)
            XCTAssertTrue(allEdited.contains("Single occurrences take the id list_events shows for each (it ends in /RID=...) with span 'this';"), allEdited)
            XCTAssertFalse(text.contains("event_id names one occurrence"), text)
            XCTAssertFalse(text.contains("This identifier names one occurrence"), text)
            XCTAssertFalse(text.contains("Use the id list_events shows for an occurrence that was not edited on its own"), text)
            XCTAssertTrue(text.hasSuffix("Nothing was written."), text)
        }
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(DetachedOccurrenceSpan.fieldsReason(wholeSeries: true)).contains(DetachedOccurrenceSpan.measuredDateRows))
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(DetachedOccurrenceSpan.recurrenceDayReason).contains("days_of_week does not hold the day of the week of that occurrence's original date"))
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(DetachedOccurrenceSpan.sameValueReason(wholeSeries: true)).contains("already holds"))
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(DetachedOccurrenceSpan.carriedReason(wholeSeries: true)).contains("would start a new series"))
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(DetachedOccurrenceSpan.firstLeftRecurrenceReason).contains("a new recurrence is refused"))
    }

    /// verify r3 (MEDIUM): through the series' id, after the first occurrence was deleted, the save
    /// starts a new series from a later slot; a rule written so was not measured there (a count from
    /// a later slot came out short, #443), so it is refused. Title and notes were measured there.
    func testARecurrenceThroughTheSeriesIdAfterADeletedFirstIsRefused() {
        let firstLeft = measured(own: .init(firstSlotGone: true), facts: .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: false))
        // `through`: the route, now the same refusal either way (verify r4); kept to name the case.
        func refusal(_ fields: Set<String>, through: Bool, _ shape: DetachedOccurrenceSpan.Neighbours) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, fields: fields,
                                                 neighbours: shape)
        }
        XCTAssertEqual(refusal(["recurrence"], through: true, firstLeft), DetachedOccurrenceSpan.firstLeftRecurrenceReason)
        XCTAssertEqual(refusal(["recurrence", "title"], through: true, firstLeft), DetachedOccurrenceSpan.firstLeftRecurrenceReason)
        XCTAssertNil(refusal(["title"], through: true, firstLeft), "measured (2026-11-08)")
        XCTAssertNil(refusal(["notes"], through: true, firstLeft), "measured (2026-11-08)")
        XCTAssertNil(refusal(["recurrence"], through: true, measured()), "the first occurrence there: no new series")
        XCTAssertEqual(refusal(["recurrence"], through: false, firstLeft), DetachedOccurrenceSpan.firstLeftRecurrenceReason,
                       "verify r4: its own id makes the same save from a later slot")
        let third = measured(earlierRemain: true, own: .init(firstSlotGone: true))
        XCTAssertNil(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, futureSpan: true,
                                                          fields: ["recurrence"], neighbours: third), "span future from a later occurrence, the first there: #416")
    }

    /// verify r5 (MEDIUM): an all-day series' /RID= is the wall-clock date read as UTC, so read raw it
    /// is not the series' first start (local midnight) in a zone other than UTC. Read as a rule slot,
    /// the edited first occurrence is the first slot.
    func testAnAllDayFirstSlotIsReadAsARuleSlot() throws {
        for zoneID in ["America/Los_Angeles", "Asia/Taipei"] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneID))
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            var utc = Calendar(identifier: .gregorian); utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
            let firstStart = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 12, day: 7)))
            let rid = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 12, day: 7)))
            let next = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 12, day: 14)))
            let firstEdited = FirstRemainingOccurrence.Candidate(eventIdentifier: "\(series)/RID=\(Int(rid.timeIntervalSince1970))", isDetached: true,
                                                                 hasRecurrenceRules: false, start: firstStart, slot: rid, slotFromRID: true)
            let unedited = FirstRemainingOccurrence.Candidate(eventIdentifier: series, isDetached: false, hasRecurrenceRules: true, start: next, slot: next)
            func facts(allDay: Bool) -> DetachedOccurrenceSpan.SeriesTimeFacts {
                DetachedOccurrenceSpan.seriesTimeFacts(of: firstEdited.eventIdentifier ?? "", among: [firstEdited, unedited], coversWholeSeries: true,
                                                       measuredRule: false, countBounded: true, firstStart: firstStart, isAllDay: allDay, zone: zone)
            }
            XCTAssertTrue(facts(allDay: true).firstSlotPresent, zoneID)
            XCTAssertTrue(UndoPostState.sameInstant(UndoPostState.ruleSlot(of: firstEdited, isAllDay: true, zone: zone), firstStart), zoneID)
            XCTAssertTrue(UndoPostState.sameInstant(UndoPostState.ruleSlot(of: unedited, isAllDay: true, zone: zone), next), "no /RID=: as listed (\(zoneID))")
        }
    }

    // MARK: - verify r7

    /// verify r7 (MEDIUM): all_day from the first left after a deleted first occurrence saves from a
    /// later slot, which #471 measured losing occurrences: refused by #428's own check, with its text.
    func testAllDayAfterADeletedFirstIsRefused() {
        let firstLeft = measured(own: .init(firstSlotGone: true), facts: .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: false))
        XCTAssertEqual(dateRefusal(["all_day"], firstLeft), DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: true))
        XCTAssertNil(dateRefusal(["all_day"], measured()), "the first occurrence there: measured")
        for key in ["start_time", "end_time", "alarms_minutes_offsets"] {
            XCTAssertNil(dateRefusal([key], firstLeft), "\(key): measured from the first left (2026-11-06, and on a started series 2026-11-08)")
        }
        XCTAssertTrue(DetachedOccurrenceSpan.measuredDateRows.contains("all_day true only while the series' first occurrence is still there"))
    }

    /// verify r7 (LOW): a time zone on a started series kept the wall-clock time across a DST change,
    /// moved occurrences that had happened and lost the last one of a counted series (measured), so
    /// both #428 routes refuse it there.
    func testATimeZoneOnAStartedSeriesIsRefused() {
        let started = measured(facts: .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: true, started: true))
        for whole in [true, false] {
            XCTAssertEqual(dateRefusal(["timezone"], whole: whole, measured(earlierRemain: !whole, facts: started.seriesTime)),
                           DetachedOccurrenceSpan.fieldsReason(wholeSeries: whole), "\(whole)")
        }
        XCTAssertNil(dateRefusal(["timezone"], measured()), "not started: measured")
        XCTAssertNil(dateRefusal(["start_time"], started), "a same-day start on a started series: #451's rules, measured")
        let first = Date(timeIntervalSinceReferenceDate: 0)
        func facts(now: Date, among: [FirstRemainingOccurrence.Candidate]) -> DetachedOccurrenceSpan.SeriesTimeFacts {
            DetachedOccurrenceSpan.seriesTimeFacts(of: edited(0).eventIdentifier ?? "", among: among, coversWholeSeries: true, measuredRule: true,
                                                   countBounded: true, firstStart: first, now: now)
        }
        XCTAssertFalse(facts(now: first.addingTimeInterval(-60), among: [edited(0), unedited(7)]).started)
        XCTAssertTrue(facts(now: first.addingTimeInterval(60), among: [edited(0), unedited(7)]).started)
        XCTAssertTrue(facts(now: first.addingTimeInterval(60), among: [unedited(7)]).started, "a deleted first slot in the past counts")
        XCTAssertTrue(DetachedOccurrenceSpan.measuredDateRows.contains("timezone only on a series that has not started"))
    }

    /// verify r7 (LOW): a #451 refusal reached through the series' id names no route that is refused
    /// there (span future with occurrence_date).
    func testAStartedSeriesRefusalReachedThroughTheSeriesIdSaysSo() {
        for allEdited in [false, true] {
            let text = DetachedOccurrenceSpan.throughSeriesIDStartedRule(allEdited: allEdited)
            XCTAssertTrue(text.hasPrefix("event_id is the series' identifier, and the occurrence that comes first in this series was edited on its own, so update_event with span 'all' went through that occurrence"), text)
            XCTAssertTrue(text.contains("#451"), text)
            XCTAssertFalse(text.contains("span 'future'"), text)
            XCTAssertTrue(text.hasSuffix("Nothing was written."), text)
        }
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesIDStartedRule(allEdited: true).contains("(it ends in /RID=...)"))
    }

    // MARK: - verify r6

    /// Runs `body` with the process' zone set to `identifier`, as the server's zone is read by
    /// default (`TimeZone.current`), and restores it.
    private func withHostZone(_ identifier: String, _ body: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", identifier, 1); tzset(); NSTimeZone.resetSystemTimeZone()
        defer {
            if let previous { setenv("TZ", previous, 1) } else { unsetenv("TZ") }
            tzset(); NSTimeZone.resetSystemTimeZone()
        }
        XCTAssertEqual(TimeZone.current.identifier, identifier)
        try body()
    }

    /// verify r6 (MEDIUM): the production calls leave the zone at its default. With the host in a zone
    /// other than the test's, an all-day first slot read in UTC or a fixed zone would fail here.
    func testAnAllDayFirstSlotIsReadInTheHostZoneByDefault() throws {
        for zoneID in ["America/Los_Angeles", "Asia/Tokyo"] {
            try withHostZone(zoneID) {
                let local = Calendar.gregorian(in: .current)
                var utc = Calendar(identifier: .gregorian); utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
                let firstStart = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 12, day: 7)))
                let rid = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 12, day: 7)))
                let next = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 12, day: 14)))
                let first = FirstRemainingOccurrence.Candidate(eventIdentifier: "\(series)/RID=\(Int(rid.timeIntervalSinceReferenceDate))", isDetached: true,
                                                           hasRecurrenceRules: false, start: firstStart, slot: rid, slotFromRID: true)
                let unedited = FirstRemainingOccurrence.Candidate(eventIdentifier: series, isDetached: false, hasRecurrenceRules: true, start: next, slot: next)
                let facts = DetachedOccurrenceSpan.seriesTimeFacts(of: first.eventIdentifier ?? "", among: [first, unedited], coversWholeSeries: true,
                                                                   measuredRule: false, countBounded: true, firstStart: firstStart, isAllDay: true)
                XCTAssertTrue(facts.firstSlotPresent, zoneID)
                XCTAssertFalse(FirstRemainingOccurrence.firstSlotDeleted(first, firstStart: firstStart, isAllDay: true), zoneID)
                XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([first, unedited], identifier: series, isAllDay: true), 0, zoneID)
                let shape = try XCTUnwrap(DetachedOccurrenceSpan.neighbours(of: first.eventIdentifier ?? "", slot: firstStart, among: [first, unedited],
                                                                           coversWholeSeries: true, isAllDay: true))
                XCTAssertFalse(shape.earlierRemain, zoneID)
                XCTAssertFalse(shape.movedPastOthers, zoneID)
            }
        }
    }

    /// verify r6 (LOW): whether a slot is a /RID= one is carried from where the candidate is built,
    /// not read from the event identifier: the external identifier can hold it too.
    func testARuleSlotFollowsWhereTheSlotCameFrom() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        var utc = Calendar(identifier: .gregorian); utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let rid = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 12, day: 7)))
        let localMidnight = try XCTUnwrap(Calendar.gregorian(in: tokyo).date(from: DateComponents(year: 2026, month: 12, day: 7)))
        let byExternal = FirstRemainingOccurrence.Candidate(eventIdentifier: "OTHER-STORE-ID", isDetached: true, hasRecurrenceRules: false,
                                                            start: localMidnight, slot: rid, sameSeriesByExternalID: true, slotFromRID: true)
        XCTAssertEqual(UndoPostState.ruleSlot(of: byExternal, isAllDay: true, zone: tokyo), localMidnight, "the RID was on the external id")
        let noDigits = FirstRemainingOccurrence.Candidate(eventIdentifier: "\(series)/RID=abc", isDetached: true, hasRecurrenceRules: false,
                                                          start: localMidnight, slot: localMidnight, slotFromRID: false)
        XCTAssertEqual(UndoPostState.ruleSlot(of: noDigits, isAllDay: true, zone: tokyo), localMidnight, "an occurrenceDate is already local")
        XCTAssertTrue(FirstRemainingOccurrence.slotIsFromRID(eventIdentifier: "OTHER", externalIdentifier: "\(series)/RID=12345"))
        XCTAssertFalse(FirstRemainingOccurrence.slotIsFromRID(eventIdentifier: "\(series)/RID=abc", externalIdentifier: nil))
    }

    /// verify r6 (LOW, option A): through the occurrence's own id, the first by slot moved to start
    /// after another occurrence takes no span 'all' or 'future' write, as the series' id does not:
    /// such a save was not measured.
    func testTheMovedFirstTakesNoWholeSeriesWriteThroughItsOwnId() throws {
        let moved = edited(7, start: 15)
        let listing = [moved, unedited(14), unedited(21)]
        let shape = try XCTUnwrap(DetachedOccurrenceSpan.neighbours(of: moved.eventIdentifier ?? "", slot: try XCTUnwrap(moved.slot), among: listing,
                                                                   coversWholeSeries: true))
        XCTAssertFalse(shape.earlierRemain)
        XCTAssertTrue(shape.movedPastOthers)
        for whole in [true, false] {
            XCTAssertEqual(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: whole, futureSpan: !whole,
                                                                fields: ["title"], neighbours: shape), DetachedOccurrenceSpan.movedFirstReason)
        }
        XCTAssertEqual(DetachedOccurrenceSpan.movedFirstDeleteRefusal(identifier: iCloudOccurrence, isDetached: true, neighbours: shape),
                       DetachedOccurrenceSpan.movedFirstDeleteReason)
        XCTAssertNil(DetachedOccurrenceSpan.movedFirstDeleteRefusal(identifier: iCloudOccurrence, isDetached: true, neighbours: noneEarlier))
        XCTAssertNil(DetachedOccurrenceSpan.movedFirstDeleteRefusal(identifier: series, isDetached: false, neighbours: shape), "not an occurrence")
        let shownBefore = try XCTUnwrap(DetachedOccurrenceSpan.neighbours(of: edited(0, start: 5).eventIdentifier ?? "", slot: Date(timeIntervalSinceReferenceDate: 0),
                                                                         among: [edited(0, start: 5), edited(7, start: 3)], coversWholeSeries: true))
        XCTAssertTrue(shownBefore.movedPastOthers, "another shown before its start")
        XCTAssertFalse(try XCTUnwrap(DetachedOccurrenceSpan.neighbours(of: edited(0, start: 5).eventIdentifier ?? "", slot: Date(timeIntervalSinceReferenceDate: 0),
                                                                       among: [edited(0, start: 5), unedited(7)], coversWholeSeries: true)).movedPastOthers)
        for text in [DetachedOccurrenceSpan.movedFirstReason, DetachedOccurrenceSpan.movedFirstDeleteReason] {
            XCTAssertTrue(text.contains("span 'this'"), text)
            XCTAssertFalse(text.contains("Use the id list_events shows for an occurrence that was not edited on its own"), text)
        }
    }

    /// verify r6 (LOW): with an earlier occurrence left, span 'all' through a later occurrence answers
    /// the split first, so the fields text does not offer what that refusal then refuses.
    func testASplitIsAnsweredBeforeTheFields() {
        XCTAssertEqual(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, fields: ["url"],
                                                            neighbours: measured(earlierRemain: true)), DetachedOccurrenceSpan.updateReason)
    }

    /// verify r5 (LOW): the fields text on the own-id route after a deleted first occurrence does not
    /// offer recurrence either.
    func testTheOwnIdFieldsTextAfterADeletedFirstLeavesOutRecurrence() {
        let firstLeft = measured(own: .init(firstSlotGone: true), facts: .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: false))
        let text = DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, fields: ["recurrence", "url"],
                                                        neighbours: firstLeft)
        XCTAssertEqual(text, DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: true))
        XCTAssertTrue(DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: true).contains("title, notes and location can be written"))
        XCTAssertFalse(DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: true).contains("location and recurrence can be written"))
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: true), firstDeleted: true)
            .contains(DetachedOccurrenceSpan.measuredDateRows), "mapped like the other fields text")
    }

    /// verify r4 (LOW): span future in the date rows was measured only from a later occurrence with
    /// the first there, a count, and no other edited occurrence.
    func testSpanFutureDatesNeedTheMeasuredRow() {
        for facts in [DetachedOccurrenceSpan.SeriesTimeFacts(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: false),
                      .init(measuredRule: true, hasEnd: false, otherEdited: false, firstSlotPresent: true),
                      .init(measuredRule: true, hasEnd: true, otherEdited: true, firstSlotPresent: true)] {
            for key in ["start_time", "end_time", "all_day", "alarms_minutes_offsets"] {
                XCTAssertEqual(dateRefusal([key], whole: false, measured(earlierRemain: true, facts: facts)), DetachedOccurrenceSpan.fieldsReason(wholeSeries: false), "\(key) \(facts)")
            }
        }
        XCTAssertNil(dateRefusal(["start_time"], whole: false, measured(earlierRemain: true)))
    }

    /// verify r4 (LOW): "a series with an end" for timezone, url and structured_location is a count:
    /// the rows were series of 5; an end date was not run.
    func testTheFirstRowFieldsNeedACountBound() {
        let first = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(DetachedOccurrenceSpan.seriesTimeFacts(of: edited(0).eventIdentifier ?? "", among: [edited(0), unedited(7)], coversWholeSeries: true,
                                                              measuredRule: true, countBounded: false, firstStart: first).hasEnd)
    }

    /// verify r4 (MEDIUM): the moved-past-next shape (first deleted, second moved after the third)
    /// gets the edited-before hint, and its text states the condition the series' id route needs,
    /// so it does not send the caller back to the call just refused. `notFoundError` itself reads the
    /// store and has no seam; these are the decisions it is made of.
    func testTheMovedPastNextShapeGetsAHintThatStatesTheCondition() {
        let listing = [edited(7, start: 15), unedited(14), unedited(21)]
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited(listing, identifier: series))
        XCTAssertTrue(FirstRemainingOccurrence.hintsEditedBefore(stored: true, refreshes: false, recurring: true, standInIgnoringTheRefusal: true))
        let condition = "and its start is not later than any other occurrence's original or shown start"
        for text in [EventKitManager.standInEditedBeforeReason, EventKitManager.standInEditedBeforeBatchReason, EventKitManager.standInAllEditedReason] {
            XCTAssertTrue(text.contains(condition), text)
            XCTAssertTrue(text.contains("Otherwise"), text)
        }
    }

    /// verify r4 (LOW): another occurrence shown before the first's start, the first not moved past
    /// the next slot: not measured either.
    func testTheEarliestEditedMustAlsoComeFirstByShownStart() {
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited([edited(0, start: 5), edited(7, start: 3), unedited(14)], identifier: series))
        XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([edited(0, start: 5), unedited(14)], identifier: series), 0)
    }

    /// verify r4 (LOW): the fields text after a deleted first occurrence does not offer recurrence.
    func testTheFieldsTextAfterADeletedFirstLeavesOutRecurrence() {
        let reason = DetachedOccurrenceSpan.fieldsReason(wholeSeries: true)
        XCTAssertTrue(DetachedOccurrenceSpan.throughSeriesID(reason).contains("Through it title, notes, location and recurrence can be written."))
        let gone = DetachedOccurrenceSpan.throughSeriesID(reason, firstDeleted: true)
        XCTAssertTrue(gone.contains("Through it title, notes and location can be written."), gone)
        XCTAssertFalse(gone.contains("and recurrence can be written"), gone)
    }

    /// verify r4 (LOW): a new days_of_week through an occurrence's id is read against its original
    /// day before #454's exemptions, which read the series' stored rule.
    func testANewRuleThroughAnOccurrenceIsCheckedAgainstTheOriginalDay() {
        XCTAssertTrue(DetachedOccurrenceSpan.refusesRecurrenceDay(originalWeekday: 2, requestedDays: [4]))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesRecurrenceDay(originalWeekday: 2, requestedDays: [2, 4]))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesRecurrenceDay(originalWeekday: nil, requestedDays: [4]), "not through an occurrence")
        XCTAssertFalse(DetachedOccurrenceSpan.refusesRecurrenceDay(originalWeekday: 2, requestedDays: nil))
        XCTAssertFalse(DetachedOccurrenceSpan.refusesRecurrenceDay(originalWeekday: 2, requestedDays: []))
    }

    /// verify r3 (INFO): a structured location rewrites the location text too, and no row had an
    /// occurrence with its own location text and a place written.
    func testAPlaceIsNotWrittenOverAnOwnLocation() {
        XCTAssertEqual(dateRefusal(["structured_location"], measured(own: .init(location: true))), DetachedOccurrenceSpan.fieldsReason(wholeSeries: true))
        XCTAssertNil(dateRefusal(["start_time"], measured(own: .init(location: true))), "a date with its own location: measured")
    }

    /// verify r3 (LOW): the earliest edited occurrence counts only while it does not start after the
    /// next one's slot: a delete from it with span future was measured only so.
    func testTheEarliestEditedMustNotStartPastTheNextSlot() {
        XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([edited(7, start: 9), unedited(14)], identifier: series), 0, "moved, still before the next")
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited([edited(7, start: 15), unedited(14)], identifier: series), "moved past the next slot")
        XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([edited(7, start: 30)], identifier: series), 0, "nothing after it")
    }

    /// Measured on iCloud (2026-11-06): each field alone, with the occurrence edited only in title,
    /// notes, location or alarms. With a time, length or day of its own, the others took it.
    func testEachMeasuredFieldGoesThroughAloneInTheMeasuredShape() {
        for key in ownTimeKeys {
            for whole in [true, false] {
                XCTAssertNil(dateRefusal([key], whole: whole, measured()), key)
                XCTAssertEqual(dateRefusal([key], whole: whole, measured(own: .init(time: true))), DetachedOccurrenceSpan.fieldsReason(wholeSeries: whole), key)
                XCTAssertEqual(dateRefusal([key], whole: whole, noneEarlier), DetachedOccurrenceSpan.fieldsReason(wholeSeries: whole, firstDeleted: whole),
                               "\(key): nothing known about the series' rule")
            }
        }
        XCTAssertNil(dateRefusal(["start_time", "end_time"], measured()), "measured together")
        XCTAssertEqual(dateRefusal(["start_time"], measured(earlierRemain: true)), DetachedOccurrenceSpan.updateReason, "an earlier occurrence left: it would still split")
    }

    /// verify r1: every other pair, and a date beside an allowed field, was not run.
    func testOnlyTheMeasuredCombinationsGoThrough() {
        for fields: Set<String> in [["start_time", "title"], ["end_time", "notes"], ["start_time", "timezone"], ["all_day", "alarms_minutes_offsets"],
                                    ["start_time", "location"], ["url", "structured_location"], ["start_time", "end_time", "all_day"],
                                    ["start_time", "recurrence"], ["url", "recurrence"]] {
            XCTAssertEqual(dateRefusal(fields, measured()), DetachedOccurrenceSpan.fieldsReason(wholeSeries: true), "\(fields)")
        }
        XCTAssertEqual(DetachedOccurrenceSpan.refusedUpdateFields(["start_time", "recurrence"], shape: measured()), ["start_time"])
        XCTAssertEqual(DetachedOccurrenceSpan.refusedUpdateFields(["title", "recurrence"], shape: measured()), [])
    }

    /// verify r1: every row was a timed weekly series every week on at most one day. Another rule,
    /// or an all-day series, takes none of these fields.
    func testOnlyTheMeasuredSeriesTakesThem() {
        let other = DetachedOccurrenceSpan.SeriesTimeFacts(measuredRule: false, hasEnd: true, otherEdited: false, firstSlotPresent: true)
        for key in ownTimeKeys {
            XCTAssertEqual(dateRefusal([key], measured(facts: other)), DetachedOccurrenceSpan.fieldsReason(wholeSeries: true), key)
        }
        func rule(_ frequency: EKRecurrenceFrequency, interval: Int = 1, days: [EKWeekday] = [], monthDays: [NSNumber]? = nil) -> EKRecurrenceRule {
            EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                             daysOfTheWeek: days.isEmpty ? nil : days.map { EKRecurrenceDayOfWeek($0) }, daysOfTheMonth: monthDays,
                             monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        }
        XCTAssertTrue(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.weekly)]))
        XCTAssertTrue(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.weekly, days: [.monday])]))
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: true, rules: [rule(.weekly)]), "all-day: its /RID= is a floating date")
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.weekly, days: [.monday, .wednesday, .friday])]),
                       "a start on another of its days was not run")
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.weekly, interval: 2)]))
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.monthly, monthDays: [15])]))
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.daily)]))
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: []))
        XCTAssertFalse(DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: false, rules: [rule(.weekly), rule(.weekly)]))
    }

    /// verify r1: timezone, url and structured_location ran only from an occurrence whose series'
    /// first slot is there, on a series with an end and no other edited occurrence.
    func testTimezoneUrlAndPlaceGoThroughOnlyInTheirRows() {
        let shapes: [(String, DetachedOccurrenceSpan.Neighbours)] = [
            ("first left", measured(own: .init(firstSlotGone: true), facts: .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: false))),
            ("open-ended", measured(facts: .init(measuredRule: true, hasEnd: false, otherEdited: false, firstSlotPresent: true))),
            ("another edited", measured(facts: .init(measuredRule: true, hasEnd: true, otherEdited: true, firstSlotPresent: true)))]
        for (name, shape) in shapes {
            for key in DetachedOccurrenceSpan.seriesTimeFieldsOfTheFirstRows {
                XCTAssertEqual(dateRefusal([key], shape), DetachedOccurrenceSpan.fieldsReason(wholeSeries: true, firstDeleted: !shape.seriesTime.firstSlotPresent),
                               "\(key), \(name)")
            }
            for key in ownTimeKeys.subtracting(DetachedOccurrenceSpan.seriesTimeFieldsOfTheFirstRows) {
                if key == "all_day", !shape.seriesTime.firstSlotPresent {
                    XCTAssertNotNil(dateRefusal([key], shape), "verify r7: all_day from the first left is refused")
                    continue
                }
                XCTAssertNil(dateRefusal([key], shape), "\(key), \(name): measured there")
            }
        }
        XCTAssertEqual(DetachedOccurrenceSpan.seriesTimeFieldsOfTheFirstRows, ["timezone", "url", "structured_location"])
    }

    /// verify r1: alarms of its own: an alarm write was not run then, a held or partly held value.
    func testAnAlarmWriteNeedsTheSeriesAlarms() {
        XCTAssertEqual(dateRefusal(["alarms_minutes_offsets"], measured(own: .init(other: true, alarms: true))),
                       DetachedOccurrenceSpan.fieldsReason(wholeSeries: true))
        XCTAssertNil(dateRefusal(["start_time"], measured(own: .init(other: true, alarms: true))), "a date with its own alarm: measured")
    }

    func testTheFactsAreReadFromTheListing() {
        let first = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(DetachedOccurrenceSpan.seriesTimeFacts(of: edited(0).eventIdentifier ?? "", among: [edited(0), unedited(7)],
                                                              coversWholeSeries: true, measuredRule: true, countBounded: true, firstStart: first,
                                                              now: first.addingTimeInterval(-day)),
                       .init(measuredRule: true, hasEnd: true, otherEdited: false, firstSlotPresent: true))
        XCTAssertEqual(DetachedOccurrenceSpan.seriesTimeFacts(of: edited(7).eventIdentifier ?? "", among: [edited(7), unedited(14), edited(21)],
                                                              coversWholeSeries: false, measuredRule: false, countBounded: true, firstStart: first,
                                                              now: first.addingTimeInterval(-day)),
                       .init(measuredRule: false, hasEnd: false, otherEdited: true, firstSlotPresent: false))
        XCTAssertEqual(DetachedOccurrenceSpan.SeriesTimeFacts(), .init(measuredRule: false, hasEnd: false, otherEdited: true, firstSlotPresent: false), "the defaults refuse")
    }

    /// `all_day: false` on an all-day series gave the others another time and an extra occurrence.
    func testAllDayFalseIsRefused() {
        XCTAssertEqual(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, fields: ["all_day"],
                                                            turnsTimed: true, neighbours: measured()),
                       DetachedOccurrenceSpan.fieldsReason(wholeSeries: true))
    }

    func testOwnTimeIsReadFromTheOccurrenceAndAnUneditedOne() {
        let slot = Date(timeIntervalSince1970: 1_800_000_000)
        let series = UndoSnapshotFixtures.event(title: "Series", startDate: slot.addingTimeInterval(7 * 86_400))
        func own(start: Date, allDay: Bool = false, to: EventSnapshot? = nil) -> Bool {
            UndoPostState.ownValues(one: UndoSnapshotFixtures.event(title: "Own", startDate: start, allDay: allDay), slot: slot, firstStart: slot, series: to ?? series).time
        }
        XCTAssertFalse(own(start: slot), "title only")
        XCTAssertTrue(own(start: slot.addingTimeInterval(7200)), "moved")
        XCTAssertTrue(own(start: slot, allDay: true), "all-day in a timed series")
        XCTAssertTrue(UndoPostState.ownValues(one: series, slot: slot, firstStart: slot, series: nil).time, "nothing to compare with")
        let longer = EKEvent(eventStore: SharedTestStore.store)
        longer.calendar = EKCalendar(for: .event, eventStore: SharedTestStore.store)
        longer.startDate = slot
        longer.endDate = slot.addingTimeInterval(3 * 3600)
        XCTAssertTrue(UndoPostState.ownValues(one: EventSnapshot(from: longer, includeRecurrence: false), slot: slot, firstStart: slot, series: series).time,
                      "a length of its own: the others took it (measured)")
    }

    private func snapshot(start: String, end: String, zone: String = "Asia/Taipei", url: String? = nil,
                          alarm: TimeInterval? = nil) -> EventSnapshot {
        let event = EKEvent(eventStore: SharedTestStore.store)
        event.calendar = EKCalendar(for: .event, eventStore: SharedTestStore.store)
        event.title = "Event"
        event.timeZone = TimeZone(identifier: zone)
        event.startDate = ISO8601DateFormatter().date(from: start)
        event.endDate = ISO8601DateFormatter().date(from: end)
        event.url = url.flatMap(URL.init(string:))
        if let alarm { event.addAlarm(EKAlarm(relativeOffset: alarm)) }
        return EventSnapshot(from: event, includeRecurrence: false)
    }

    /// verify r1 (coincidence): the occurrence back at its slot, while the series moved to another
    /// time or day, is not in the measured shape; nor is one with its own URL.
    func testOwnTimeComparesTheSeriesTimeOfDayAndDayAndTheOtherFields() throws {
        let unedited = snapshot(start: "2026-12-14T01:00:00Z", end: "2026-12-14T02:00:00Z") // Monday 09:00-10:00 in Taipei
        let atSlot = snapshot(start: "2026-12-07T02:00:00Z", end: "2026-12-07T03:00:00Z")   // Monday 10:00-11:00
        let slot = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-07T02:00:00Z"))
        func time(_ one: EventSnapshot, _ all: EventSnapshot) -> Bool { UndoPostState.ownValues(one: one, slot: slot, firstStart: slot, series: all).time }
        XCTAssertTrue(time(atSlot, unedited), "at its slot, but the series is at 09:00 now")
        let sameTime = snapshot(start: "2026-12-14T02:00:00Z", end: "2026-12-14T03:00:00Z")
        XCTAssertFalse(time(atSlot, sameTime))
        XCTAssertTrue(time(atSlot, snapshot(start: "2026-12-16T02:00:00Z", end: "2026-12-16T03:00:00Z")), "the series moved to Wednesday")
        XCTAssertTrue(time(snapshot(start: "2026-12-07T02:00:00Z", end: "2026-12-07T03:00:00Z", url: "https://example.com/a"), sameTime), "its own URL")
        // Availability cannot be set on a test event (no source supports it, it reads -1), and a side
        // that reports none is not compared (#245); `ownValues` reads it with `sameOccurrenceAvailability`.
        let ownAlarm = UndoPostState.ownValues(one: snapshot(start: "2026-12-07T02:00:00Z", end: "2026-12-07T03:00:00Z", alarm: -900),
                                               slot: slot, firstStart: slot, series: sameTime)
        XCTAssertFalse(ownAlarm.time, "alarms of its own are in the measured shape")
        XCTAssertTrue(ownAlarm.alarms)
        XCTAssertTrue(UndoPostState.ownValues(one: atSlot, slot: slot, firstStart: slot, series: nil).alarms, "nothing to compare with")
    }

    /// verify r1 (LOW): a length across a DST change is the same wall-clock length.
    func testALengthAcrossADSTChangeIsTheSeriesLength() throws {
        // New York, overnight 22:00-06:00: seven hours of elapsed time on the night of 2027-03-14.
        let overDST = snapshot(start: "2027-03-14T03:00:00Z", end: "2027-03-14T10:00:00Z", zone: "America/New_York")
        let normal = snapshot(start: "2027-03-21T02:00:00Z", end: "2027-03-21T10:00:00Z", zone: "America/New_York")
        let slot = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-14T03:00:00Z"))
        XCTAssertFalse(UndoPostState.ownValues(one: overDST, slot: slot, firstStart: slot, series: normal).time)
        XCTAssertTrue(UndoPostState.sameWallClock(overDST, normal, zone: TimeZone(identifier: "America/New_York")!))
        XCTAssertFalse(UndoPostState.sameWallClock(overDST, normal, zone: TimeZone(identifier: "UTC")!), "read in UTC the lengths differ")
    }

    // MARK: - The series' id with the first occurrence edited (#428)

    func testTheEarliestEditedOccurrenceIsPickedOnlyWhenItComesFirst() {
        XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([unedited(7), edited(0), unedited(14)], identifier: series), 1)
        XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([unedited(14), edited(7), edited(21)], identifier: series), 1, "the first left")
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited([unedited(0), edited(7)], identifier: series), "an unedited occurrence first")
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited([edited(0, id: "CAL-9:OTHER/RID=1"), unedited(7)], identifier: series), "not under this id: not measured")
        XCTAssertNil(FirstRemainingOccurrence.earliestEdited([], identifier: series))
        XCTAssertEqual(FirstRemainingOccurrence.earliestEdited([unedited(7), edited(0, start: 5)], identifier: series), 1, "by slot, not by the time it shows")
    }

    /// A source pin, and only that: the routing happens inside `EventKitManager` on the event store,
    /// which no seam reaches. What it reports is tested on its own: the id through
    /// `UpdatedIdentifierTests.testTheFirstOccurrenceRouteReportsTheSeriesOfTheSavedId`, the delete's
    /// answer and that only span 'all' gets here through `EventDeletionHandlerTests`, and the first
    /// occurrence it picks through `testTheEarliestEditedOccurrenceIsPickedOnlyWhenItComesFirst`. That
    /// the routes do what they say (every occurrence updated or deleted, open-ended series included)
    /// was measured on iCloud (2026-11-06 and 2026-11-08), not here.
    func testUpdateAndDeleteGoThroughTheFirstOccurrence() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(manager.contains("if applyToAll, let first = try firstEditedOccurrenceID(of: identifier) {"), "update")
        XCTAssertTrue(manager.contains("} catch EventKitError.occurrenceAddressRefused(let reason) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.throughSeriesID(reason, allEdited: first.allEdited, firstDeleted: first.firstDeleted)) }"), "verify r2: the text says the series' id")
                XCTAssertTrue(manager.contains("return (saved.event, UpdatedIdentifier.seriesThroughOccurrence(saved: saved.event.eventIdentifier), saved.matchedOccurrence)"))
        XCTAssertTrue(manager.contains("if let first = try firstEditedOccurrenceID(of: identifier) { try await deleteEvent(identifier: first.id, span: .futureEvents) return .firstEditedOccurrence(id: first.id) }"), "delete")
    }

    /// Every update route ends here and not at another call, and says no more: each longer version
    /// was false for some field (span `this` does not take `recurrence` or `clear_recurrence` in
    /// these shapes, and `move_events_batch` takes a calendar).
    private let noTestedWay = "If that id is refused, this shape has no tested way yet."

    func testNoRefusalPointsBackAtACallThatIsRefused() {
        for whole in [true, false] {
            for reason in [DetachedOccurrenceSpan.sameValueReason(wholeSeries: whole), DetachedOccurrenceSpan.carriedReason(wholeSeries: whole)] {
                XCTAssertTrue(reason.contains(noTestedWay), reason)
            }
        }
        XCTAssertTrue(DetachedOccurrenceSpan.updateReason.contains("If that is refused, this shape has no tested way yet."), DetachedOccurrenceSpan.updateReason)
        for text in [EventKitManager.standInEditedBeforeReason, EventKitManager.standInEditedBeforeBatchReason] {
            XCTAssertTrue(text.contains("A write from a date on through the series' id has no tested way yet;"), text)
            XCTAssertFalse(text.contains("Anything else has no tested way yet."), "verify r1: the series' id takes more now: \(text)")
        }
        for reason in [DetachedOccurrenceSpan.fieldsReason(wholeSeries: true), DetachedOccurrenceSpan.fieldsReason(wholeSeries: false),
                       DetachedOccurrenceSpan.sameValueReason(wholeSeries: true), DetachedOccurrenceSpan.carriedReason(wholeSeries: false),
                       DetachedOccurrenceSpan.updateReason, EventKitManager.standInEditedBeforeReason] {
            for claim in ["no single call", "open-ended"] { XCTAssertFalse(reason.contains(claim), reason) }
        }
    }

    /// The words of `seriesTimeAllowed`: every condition the code reads, and the one-way all_day.
    func testTheMeasuredRowsTextNamesEveryCondition() {
        let text = DetachedOccurrenceSpan.measuredDateRows
        for phrase in ["a timed series repeating weekly, every week, on at most one day",
                       "each in a call of its own with nothing else written (start_time with end_time may go together)",
                       "at its original start and differing from an occurrence not edited on its own only in title, notes, location or alarms",
                       "start_time and end_time only as a new time of day, the start and the end staying on the dates they are on",
                       "alarms while it has the series' alarms",
                       "timezone, url and structured_location only in a series that ends after a number of occurrences, whose first occurrence is still there and which has no other occurrence edited on its own",
                       "all_day true has no way back through this id: all_day false is refused, and so are dates on an all-day series.",
                       "later dates through it are refused."] {
            XCTAssertTrue(text.contains(phrase), phrase)
        }
    }

    func testTheFieldsRefusalNamesOnlyRoutesThatWereRun() {
        let all = DetachedOccurrenceSpan.fieldsReason(wholeSeries: true)
        for phrase in ["with span 'all' through it title, notes, location and recurrence can be written.",
                       DetachedOccurrenceSpan.measuredDateRows,
                       "Any other field or combination is refused, even one that changes nothing.",
                       "Use the id list_events shows for an occurrence that was not edited on its own, with span 'all'.",
                       "Occurrences edited on their own keep what was edited, so they may need span 'this' after that.",
                       noTestedWay,
                       "That id leaves out all_day, which brings an edited occurrence's original slot back as an extra occurrence, clear_timezone, which drops the last occurrence of a series with a count, and a calendar of another account, which was not tried; clear_recurrence there leaves one event at the series' first date, without the edited occurrences.",
                       "For a calendar of the same account, move_events_batch with span 'all' moves the whole series."] {
            XCTAssertTrue(all.contains(phrase), all)
        }
        let future = DetachedOccurrenceSpan.fieldsReason(wholeSeries: false)
        XCTAssertTrue(future.contains("with span 'future' through it title, notes, location and recurrence can be written."), future)
        XCTAssertTrue(future.contains("Use span 'this' on this occurrence, and for the later ones the id list_events shows for the next occurrence that was not edited on its own, with its occurrence_date and span 'future'."), future)
        XCTAssertTrue(future.contains("That way leaves out all_day, clear_recurrence and calendar_name, which do not stay within the later occurrences, and clear_timezone, which was not tried."), future)
        XCTAssertTrue(future.contains(noTestedWay), future)
        XCTAssertFalse(future.contains("span 'all'"), future)
        for reason in [all, future] { XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason) }
    }

    // MARK: - A value the occurrence already holds (round 5)

    /// Measured: the first occurrence's location R101, the same R101 through its id with span `all`,
    /// answered updated, and the other 4 did not change. The same with span `future`, and for title
    /// and notes. A new value does reach them, so it is the repeat that is refused.
    func testAValueTheOccurrenceAlreadyHoldsIsRefused() {
        func repeats(title: String? = nil, notes: String? = nil, location: String? = nil) -> Bool {
            DetachedOccurrenceSpan.repeatsOccurrenceValue(title: title, notes: notes, location: location,
                                                          occurrenceTitle: "Own", occurrenceNotes: nil, occurrenceLocation: "R101")
        }
        XCTAssertTrue(repeats(location: "R101"))
        XCTAssertTrue(repeats(title: "Own"))
        XCTAssertTrue(repeats(notes: ""), "nil and empty text are the same")
        XCTAssertTrue(repeats(title: "New", location: "R101"), "the title would go, the location would not: measured")
        XCTAssertFalse(repeats(location: "R102"))
        XCTAssertFalse(repeats())
        for (whole, future) in [(true, false), (false, true)] {
            XCTAssertEqual(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: whole, futureSpan: future,
                                                                fields: ["location"], repeatsOccurrenceValue: true, neighbours: noneEarlier),
                           DetachedOccurrenceSpan.sameValueReason(wholeSeries: whole))
        }
        XCTAssertNil(DetachedOccurrenceSpan.updateRefusal(identifier: series, isDetached: false, wholeSeries: true,
                                                          fields: ["location"], repeatsOccurrenceValue: true, neighbours: noneEarlier))
    }

    func testTheSameValueRefusalSaysWhatWouldHappen() {
        let reason = DetachedOccurrenceSpan.sameValueReason(wholeSeries: true)
        XCTAssertTrue(reason.contains("a title, notes or location equal to what this occurrence already holds reaches no other occurrence, though the call would answer updated"), reason)
        XCTAssertTrue(reason.contains("Leave that field out if it is not meant to change."), reason)
        XCTAssertTrue(reason.contains("with span 'all'"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    // MARK: - What a new series takes from the occurrence (round 5)

    private func shape(earlierRemain: Bool, firstSlotGone: Bool = false, location: Bool = false, other: Bool = false) -> DetachedOccurrenceSpan.Neighbours {
        .init(earlierRemain: earlierRemain, othersRemain: true, own: .init(firstSlotGone: firstSlotGone, location: location, other: other))
    }

    /// Measured: span `future` from the third occurrence, and span `all` from the first left, gave
    /// the new series this occurrence's location and alarms, even when only `title` was written.
    /// From the first occurrence nothing was carried.
    func testAWriteThatStartsANewSeriesIsRefusedWhileTheOccurrenceHoldsValuesOfItsOwn() {
        func future(_ known: DetachedOccurrenceSpan.Neighbours, _ fields: Set<String> = ["title"]) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, futureSpan: true, fields: fields, neighbours: known)
        }
        func all(_ known: DetachedOccurrenceSpan.Neighbours, _ fields: Set<String> = ["title"]) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, fields: fields, neighbours: known)
        }
        let carried = DetachedOccurrenceSpan.carriedReason(wholeSeries: false)
        XCTAssertEqual(future(shape(earlierRemain: true, location: true)), carried)
        XCTAssertEqual(future(shape(earlierRemain: true, other: true)), carried)
        XCTAssertEqual(future(shape(earlierRemain: false, firstSlotGone: true, location: true)), carried)
        XCTAssertEqual(all(shape(earlierRemain: false, firstSlotGone: true, other: true)), DetachedOccurrenceSpan.carriedReason(wholeSeries: true))
        XCTAssertNil(future(shape(earlierRemain: true)), "nothing of its own to carry")
        XCTAssertNil(future(shape(earlierRemain: false, location: true, other: true)), "the first occurrence starts no new series")
        XCTAssertNil(all(shape(earlierRemain: false, location: true, other: true)), "the same with span all")
        func writing(_ known: DetachedOccurrenceSpan.Neighbours, location: Bool) -> String? {
            DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: false, futureSpan: true,
                                                 fields: ["location"], writesLocation: location, neighbours: known)
        }
        XCTAssertNil(writing(shape(earlierRemain: true, location: true), location: true), "a written location replaces it: measured")
        XCTAssertEqual(writing(shape(earlierRemain: true, location: true, other: true), location: true), carried, "the alarms would still go")
        XCTAssertEqual(writing(shape(earlierRemain: true, location: true), location: false), carried, "a location key whose value is no text writes nothing")
    }

    func testTheCarriedRefusalSaysWhatWouldHappen() {
        let reason = DetachedOccurrenceSpan.carriedReason(wholeSeries: false)
        XCTAssertTrue(reason.contains("this call would start a new series from this occurrence, and that series would take values this occurrence holds on its own, such as its location or alarms"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    /// Compared with an occurrence not edited on its own. Title, notes and time are not carried
    /// (measured), so they do not count.
    func testOwnValuesCompareWhatANewSeriesWouldTake() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let later = start.addingTimeInterval(7 * 86_400)
        let series = UndoSnapshotFixtures.event(title: "Series", startDate: later)
        func own(_ one: EventSnapshot, slot: Date, first: Date, against: EventSnapshot? = nil) -> DetachedOccurrenceSpan.OwnValues {
            UndoPostState.ownValues(one: one, slot: slot, firstStart: first, series: against)
        }
        XCTAssertEqual(own(UndoSnapshotFixtures.event(title: "Own", startDate: later.addingTimeInterval(7200)), slot: start, first: start, against: series),
                       .init(time: true), "title and time are not carried")
        XCTAssertTrue(own(series, slot: later, first: start, against: series).firstSlotGone)
        XCTAssertEqual(own(series, slot: later, first: start),
                       .init(firstSlotGone: true, location: true, other: true, time: true, alarms: true), "nothing to compare with: the side that refuses")
    }

    /// A source where an edited occurrence keeps the series' identifier (not measured): the series'
    /// id plus `occurrence_date` reaches it, and only the resolved object shows it. The save is the
    /// one measured through the occurrence's own id, so every check runs, and what cannot be judged
    /// there is refused.
    func testAnEditedOccurrenceReachedByItsDateTakesEveryCheck() {
        func refusal(ownId: Bool = false, detached: Bool = true, future: Bool = true, _ fields: Set<String> = ["title"], repeats: Bool = false,
                     writesLocation: Bool = false, own: DetachedOccurrenceSpan.OwnValues? = .init()) -> String? {
            DetachedOccurrenceSpan.resolvedOccurrenceRefusal(addressedByItsOwnId: ownId, resolvedIsDetached: detached, futureSpan: future, fields: fields,
                                                             repeatsOccurrenceValue: repeats, writesLocation: writesLocation, own: own)
        }
        XCTAssertEqual(refusal(["start_time"]), DetachedOccurrenceSpan.fieldsReason(wholeSeries: false))
        XCTAssertEqual(refusal(repeats: true), DetachedOccurrenceSpan.sameValueReason(wholeSeries: false), "a value it holds")
        let carried = DetachedOccurrenceSpan.carriedReason(wholeSeries: false)
        XCTAssertEqual(refusal(own: .init(location: true)), carried, "its own location")
        XCTAssertEqual(refusal(own: .init(other: true)), carried, "its own alarms")
        XCTAssertEqual(refusal(own: nil), carried, "nothing to compare with: the side that refuses")
        XCTAssertNil(refusal(["location"], writesLocation: true, own: .init(location: true)), "a written location replaces it")
        XCTAssertEqual(refusal(["location"], writesLocation: true, own: .init(location: true, other: true)), carried, "the alarms would still go")
        XCTAssertNil(refusal(), "an occurrence with nothing of its own")
        XCTAssertNil(refusal(ownId: true, ["start_time"]), "checked already")
        XCTAssertNil(refusal(detached: false, ["start_time"]), "an ordinary occurrence")
        XCTAssertNil(refusal(future: false, ["start_time"]), "span this")
    }

    /// An all-day `/RID=` is a floating date, the wall-clock date read as UTC. Read as an instant it
    /// never equals the series' local midnight off UTC, so the first occurrence read as deleted and
    /// a correct call was refused, and west of UTC the day read as the one before.
    func testAnAllDayRidIsReadAsItsDateInEveryZone() throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let floating = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 12, day: 7)))
        let id = "CAL-1:SERIES-1/RID=\(Int(floating.timeIntervalSinceReferenceDate))"
        for name in ["UTC", "Asia/Taipei", "America/Los_Angeles", "Pacific/Pago_Pago", "Pacific/Kiritimati"] {
            let zone = try XCTUnwrap(TimeZone(identifier: name))
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            let midnight = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 12, day: 7)))
            XCTAssertEqual(UndoPostState.ruleSlot(eventIdentifier: id, externalIdentifier: nil, occurrenceDate: nil, isAllDay: true, zone: zone), midnight, name)
            let day = try XCTUnwrap(DetachedOccurrenceSpan.originalDay(identifier: id, isDetached: true, wholeSeries: true, futureSpan: false,
                                                                       externalIdentifier: nil, occurrenceDate: nil, isAllDay: true, zone: zone))
            XCTAssertEqual(local.component(.weekday, from: day), 2, "Monday in \(name)")
            let series = UndoSnapshotFixtures.event(title: "Series", startDate: midnight, allDay: true)
            XCTAssertFalse(UndoPostState.ownValues(one: series, slot: day, firstStart: midnight, series: series).firstSlotGone, name)
        }
    }

    /// A timed `/RID=` is an instant, and with no `/RID=` the occurrence date is already local.
    func testATimedRidAndAMissingRidAreLeftAlone() throws {
        let instant = Date(timeIntervalSinceReferenceDate: 818_301_600)
        XCTAssertEqual(UndoPostState.ruleSlot(eventIdentifier: "S/RID=818301600", externalIdentifier: nil, occurrenceDate: nil, isAllDay: false), instant)
        XCTAssertEqual(UndoPostState.ruleSlot(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: instant, isAllDay: true), instant)
        XCTAssertNil(UndoPostState.ruleSlot(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: nil, isAllDay: true))
    }

    /// The only occurrence left starts a new series with nothing to carry to (measured in round 1:
    /// updated, new id), so the carried refusal does not apply.
    func testTheOnlyOccurrenceLeftHasNothingToCarryTo() {
        let left = DetachedOccurrenceSpan.Neighbours(earlierRemain: false, othersRemain: false,
                                                     own: .init(firstSlotGone: true, location: true, other: true))
        XCTAssertNil(DetachedOccurrenceSpan.updateRefusal(identifier: iCloudOccurrence, isDetached: true, wholeSeries: true, fields: ["title"], neighbours: left))
    }

    /// Its own alarm and location, as such a source would hold them.
    func testOwnValuesOfAnOccurrenceHoldingAnAlarmAndALocation() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(location: String? = nil, alarm: Int? = nil, latitude: Double? = nil) -> EventSnapshot {
            let event = EKEvent(eventStore: SharedTestStore.store)
            event.calendar = EKCalendar(for: .event, eventStore: SharedTestStore.store)
            event.title = "Event"
            event.startDate = start
            event.endDate = start.addingTimeInterval(3600)
            event.location = location
            if let alarm { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alarm * 60))) }
            if let latitude {
                let place = EKStructuredLocation(title: location ?? "Hall")
                place.geoLocation = CLLocation(latitude: latitude, longitude: 121.5)
                event.structuredLocation = place
            }
            return EventSnapshot(from: event, includeRecurrence: false)
        }
        func own(_ one: EventSnapshot) -> DetachedOccurrenceSpan.OwnValues {
            UndoPostState.ownValues(one: one, slot: start, firstStart: start, series: snapshot())
        }
        XCTAssertEqual(own(snapshot()), .init())
        XCTAssertTrue(own(snapshot(location: "R101")).location)
        XCTAssertFalse(own(snapshot(location: "R101")).other, "text only: a written location replaces it (measured)")
        XCTAssertTrue(own(snapshot(alarm: 5)).other)
        XCTAssertTrue(own(snapshot(latitude: 25)).other, "coordinates of its own: not shown to be replaced by a written location")
        func against(_ all: EventSnapshot, _ one: EventSnapshot) -> DetachedOccurrenceSpan.OwnValues {
            UndoPostState.ownValues(one: one, slot: start, firstStart: start, series: all)
        }
        XCTAssertFalse(against(snapshot(location: "Hall"), snapshot(location: "Hall", latitude: 25)).other, "the series' place, geocoded: no edit")
        XCTAssertFalse(against(snapshot(location: "Hall", latitude: 25), snapshot(location: "R101")).other, "text over a place with coordinates: none to carry")
    }

    /// `/RID=` is enough to name one occurrence, so it is enough for the day too: the slot is read
    /// from it, not from the day the occurrence shows.
    func testTheOriginalDayIsReadWithTheRidAloneAcrossAWeekdayMove() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let calendar = Calendar.gregorian(in: zone)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 7, hour: 10)))
        let wednesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: monday))
        let id = "CAL-1:SERIES-1/RID=\(Int(monday.timeIntervalSinceReferenceDate))"
        func day(_ id: String, detached: Bool, all: Bool = true, future: Bool = false) -> Date? {
            DetachedOccurrenceSpan.originalDay(identifier: id, isDetached: detached, wholeSeries: all, futureSpan: future,
                                               externalIdentifier: nil, occurrenceDate: wednesday, isAllDay: false, zone: zone)
        }
        XCTAssertEqual(day(id, detached: false), monday, "/RID= with isDetached false")
        XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(day(id, detached: false))), 2, "Monday, not the Wednesday it shows")
        XCTAssertEqual(day(id, detached: true, all: false, future: true), monday)
        XCTAssertEqual(day(otherSourceOccurrence, detached: true), wednesday, "no /RID=: its occurrence date")
        XCTAssertNil(day(series, detached: false), "the series' own id")
        XCTAssertNil(day(id, detached: true, all: false), "span this")
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
    /// #428 refuses it when the first occurrence was edited at its original start, and the series' id plus the edited
    /// occurrence's date does not reach that occurrence.
    private let routeToTheFirst = "the id list_events shows for the occurrence that comes first in the series (by its original date, not a time it was moved to)"

    func testTheUpdateRefusalSaysWhatWouldHappenAndNamesRoutesThatWork() {
        let reason = DetachedOccurrenceSpan.updateReason
        XCTAssertTrue(reason.contains("span 'all' through it would split the series here"), reason)
        XCTAssertTrue(reason.contains("the earlier occurrences would stay in the old series"), reason)
        XCTAssertTrue(reason.contains("To update the whole series, use \(routeToTheFirst) with span 'all'."), reason)
        XCTAssertTrue(reason.contains("If that is refused, this shape has no tested way yet."), reason)
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
        XCTAssertEqual(DetachedOccurrenceSpan.occurrenceRowsFirst(["S", "S/RID=abc", "S/RID=4", "T/RID=1"]), ["T/RID=1", "S/RID=4", "S/RID=abc", "S"],
                       "a slot that is no number comes after the numbered ones, before the bare ids; two series side by side")
    }

    /// #416 measured that the occurrence which comes first reaches the series through its own id, and
    /// #428 sends span 'all' through the series' id there (measured, iCloud 2026-11-06 and -08), so
    /// the hint names that route, in words a batch caller can use too.
    func testTheEditedBeforeHintsNameTheOwnIdRoute() {
        for text in [EventKitManager.standInEditedBeforeReason, EventKitManager.standInEditedBeforeBatchReason] {
            XCTAssertTrue(text.contains("When the occurrence that comes first in the series was edited on its own and its start is not later than any other occurrence's original or shown start, update_event and delete_event with span 'all' through the series' id go through it: update_event writes the fields its description lists for such an occurrence, and delete_event deletes every occurrence, which cannot be undone."), text)
            XCTAssertTrue(text.contains("span 'future' through the id of a later occurrence edited on its own takes title, notes, location and recurrence."), text)
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
        XCTAssertTrue(head.contains("if let refusal = try DetachedOccurrenceSpan.updateRefusal( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, futureSpan: span == .futureEvents, fields: fields, repeatsOccurrenceValue: DetachedOccurrenceSpan.repeatsOccurrenceValue( title: title, notes: notes, location: location, occurrenceTitle: masterEvent.title, occurrenceNotes: masterEvent.notes, occurrenceLocation: masterEvent.location), writesLocation: location != nil, turnsTimed: isAllDay == false, datesStayOnTheDay: DetachedOccurrenceSpan.datesStayOnTheDay( newStart: startDate, newEnd: endDate, start: masterEvent.startDate, end: masterEvent.endDate, zone: masterEvent.timeZone ?? .current), neighbours: ownNeighbours) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), head)
    }

    /// Before the first field is assigned, as #373 requires of every refusal.
    func testTheOtherRefusalsOfAnUpdateComeBeforeTheFirstAssignment() throws {
        let body = try updateBody()
        XCTAssertTrue(body.contains("if let refusal = DetachedOccurrenceSpan.resolvedOccurrenceRefusal( addressedByItsOwnId: event === masterEvent, resolvedIsDetached: event.isDetached, futureSpan: span == .futureEvents && !applyToAll, fields: fields, repeatsOccurrenceValue: DetachedOccurrenceSpan.repeatsOccurrenceValue( title: title, notes: notes, location: location, occurrenceTitle: event.title, occurrenceNotes: event.notes, occurrenceLocation: event.location), writesLocation: location != nil, own: UndoPostState.ownValues(ofResolved: event, series: masterEvent)) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), body)
        XCTAssertTrue(body.contains("DetachedOccurrenceSpan.refusesOccurrenceDate( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, hasOccurrenceDate: occurrenceDate != nil, matches: occurrenceDateMatches(occurrenceDate, occurrence: masterEvent, id: identifier))"), body)
    }

    /// A new start through an occurrence's id with span `all` or `future` is checked against the
    /// series' rules, as the detached object has none. A new `days_of_week` is read from the original
    /// day: measured, a rule on the day a moved first occurrence shows left two occurrences there.
    func testTheWeekdayCheckReadsTheEventsOwnRulesAndTheOriginalDay() throws {
        let body = try updateBody()
        XCTAssertTrue(body.contains("let storedRule = clearRecurrence ? nil : (detachedWrite ? try seriesObject(ofOccurrence: identifier)?.recurrenceRules : event.recurrenceRules)?.first"), body)
        XCTAssertTrue(body.contains("let originalDay = startDate != nil ? nil : DetachedOccurrenceSpan.originalDay( identifier: identifier, isDetached: event.isDetached, wholeSeries: applyToAll, futureSpan: span == .futureEvents, externalIdentifier: event.calendarItemExternalIdentifier, occurrenceDate: event.occurrenceDate, isAllDay: event.isAllDay)"), body)
        XCTAssertTrue(body.contains("of: originalDay ?? datePlan.datesToWrite?.start ?? event.startDate"), body)
        XCTAssertTrue(body.contains("if originalDay != nil, effectiveRule != nil { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.recurrenceDayReason) }"), body)
        XCTAssertTrue(DetachedOccurrenceSpan.recurrenceDayReason.contains("Add that day, or leave days_of_week out."))
    }

    /// The call's keys, not its parsed values: that is what makes a new parameter refused by default.
    func testTheFieldsComeFromTheCallsKeys() throws {
        let source = SourceScan.strippingComments(try SourcePins.source("Server.swift"))
        XCTAssertTrue(source.contains("fields: Set(arguments.filter { $0.value != .null }.keys),"))
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventWriteSource.swift")))
        XCTAssertTrue(manager.contains("identifier: request.identifier, fields: request.fields,"), manager)
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
        XCTAssertTrue(body.contains("UndoPostState.ruleSlot(eventIdentifier: id, externalIdentifier: occurrence.calendarItemExternalIdentifier, occurrenceDate: occurrence.occurrenceDate, isAllDay: series.isAllDay)"), body)
        XCTAssertTrue(body.contains("SeriesExceptionsPlanner.listingRanges(for: window).map(\\.end).max()"), body)
        XCTAssertTrue(body.contains("own: UndoPostState.ownValues(of: occurrence, slot: slot, firstStart: firstStart, series: listed.first { !$0.isDetached })"), body)
        XCTAssertTrue(body.contains("let covers = DetachedOccurrenceSpan.coversWholeSeries( rules: rules.map(DetachedOccurrenceSpan.RuleExtent.init), firstStart: firstStart, scannedTo: scannedTo, calendar: Calendar.gregorian(in: series.timeZone ?? .current))"), body)
        XCTAssertTrue(body.contains("let rules = series.recurrenceRules ?? []"), body)
        // #428 verify r1: the facts of the series' rule come from the same series object and listing.
        XCTAssertTrue(body.contains("known?.seriesTime = DetachedOccurrenceSpan.seriesTimeFacts( of: id, among: candidates, coversWholeSeries: covers, measuredRule: DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: series.isAllDay, rules: rules), countBounded: !rules.isEmpty && rules.allSatisfy { ($0.recurrenceEnd?.occurrenceCount ?? 0) > 0 }, firstStart: firstStart, isAllDay: series.isAllDay)"), body)
    }

    /// Covered on a device only until round 3: each would fail silently.
    func testTheRoundTwoWiringIsPinned() throws {
        let manager = try updateBody()
        XCTAssertTrue(manager.contains("if occurrenceDate != nil, !applyToAll, DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: masterEvent.isDetached) { matchedOccurrence = MatchedOccurrence(start: masterEvent.startDate, zone: Self.occurrenceZone(of: masterEvent)) }"), manager)
        let source = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")))
        XCTAssertTrue(source.contains("return [occurrence.startDate, slot].contains {"), "the shown day or the original one")
        XCTAssertTrue(source.contains("neighbours: try occurrenceNeighbours(of: event, id: id, namedInTheCall: namedInTheCall))"))
        XCTAssertTrue(source.contains("namedInTheCall: namedInTheCall)"))
    }

    func testTheEventIdsRowsRunThroughTheOrdering() throws {
        let source = SourceScan.strippingComments(try SourcePins.source("Server.swift"))
        XCTAssertTrue(source.contains("let uniqueIds = DetachedOccurrenceSpan.occurrenceRowsFirst(items.map(\\.identifier))"))
    }

    func testTheSeriesDeletesCheckBeforeTheyRemove() throws {
        let single = try collapsed("func deleteEventSeries(identifier: String)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(single.contains("if let refusal = try seriesDeleteRefusal(event, id: identifier) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), single)
        let batch = try collapsed("func deleteEventSeriesBatch(identifiers: [String], refusingOccurrenceIdentifiers: Bool)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(batch.contains("if refusingOccurrenceIdentifiers, let refusal = try seriesDeleteRefusal(event, id: id, namedInTheCall: Set(identifiers), batch: true) { failures.append((id, refusal)) continue }"), batch)
    }

    /// The preview by `event_ids` walks the rows as the real call does and does not list what the
    /// real call refuses. `DeleteEventsBatchHandlerTests` compares the answers;
    /// the manager's side reads the store, so it is pinned here.
    func testTheDryRunByEventIdsUsesTheRefusal() throws {
        let server = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("Server.swift")))
        XCTAssertTrue(server.contains("let rows = spanAll ? DetachedOccurrenceSpan.occurrenceRowsFirst(eventIds) : eventIds"), "the real call's order")
        XCTAssertTrue(server.contains("identifier: id, span: spanStr == \"future\" ? .futureEvents : .thisEvent, spanAll: spanAll, namedInTheCall: named, goneInTheCall: gone"), server)
        let source = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventBatchDeletionSource.swift")))
        XCTAssertTrue(source.contains("guard let event = try freshEventWithOrigin( id: identifier, refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span, wholeSeries: spanAll), goneInTheCall: goneInTheCall)?.event else { throw notFoundError(id: identifier) }"), source)
        XCTAssertTrue(source.contains("if !spanAll, event.hasRecurrenceRules { return .refused(Self.batchOccurrenceDateRequired) }"), source)
        XCTAssertTrue(source.contains("if spanAll, let refusal = try seriesDeleteRefusal(event, id: identifier, namedInTheCall: namedInTheCall, batch: true) { return .refused(refusal) }"), source)
        let scan = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")))
        XCTAssertTrue(scan.contains("FirstRemainingOccurrence.pick(candidates, identifier: id, refuseWhenEditedBefore: refuseWhenEditedBefore, goneInTheCall: goneInTheCall)"), scan)
    }
}
