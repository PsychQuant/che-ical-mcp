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
/// through such an identifier does what the span says and is not refused. These are the
/// coordinator's defaults while the maintainer has not answered.
///
/// The neighbours come from a scan of the series. An occurrence with no series to scan (no `/RID=`
/// on another source, #320, not checked) has unknown neighbours and is refused: nothing is written.
final class DetachedOccurrenceSpanTests: XCTestCase {
    private let series = "CAL-1:SERIES-1"
    private let iCloudOccurrence = "CAL-1:SERIES-1/RID=826768800"
    /// What #320 expects of other sources, not checked: no `/RID=` slot.
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
                      "isDetached alone is enough (#320 expects no /RID= on other sources)")
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

    func testEveryRuleHasToFit() {
        let calendar = Calendar(identifier: .gregorian)
        let fits = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5)))
        let open = DetachedOccurrenceSpan.RuleExtent(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        XCTAssertFalse(DetachedOccurrenceSpan.coversWholeSeries(rules: [fits, open], firstStart: first, scannedTo: scannedTo(ruleEnd: nil), calendar: calendar))
        XCTAssertFalse(DetachedOccurrenceSpan.coversWholeSeries(rules: [], firstStart: first, scannedTo: scannedTo(ruleEnd: nil), calendar: calendar),
                       "no rule read: nothing is shown")
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
        XCTAssertFalse(refused(span: .thisEvent, clears: true), "span this keeps its own checks (#426)")
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

    func testTheSeriesPropertyRefusalSaysWhyAndOffersAnUneditedOccurrence() {
        let reason = DetachedOccurrenceSpan.seriesPropertyReason
        for phrase in ["cannot take clear_recurrence or a calendar of another account",
                       "clear_recurrence through it would answer updated and change nothing",
                       "use the id list_events shows for an occurrence that was not edited on its own, with span 'all'",
                       "if that is refused too, the change is not supported on this series"] {
            XCTAssertTrue(reason.contains(phrase), reason)
        }
        XCTAssertFalse(reason.contains("recurrence, clear_recurrence"), "a new recurrence goes through: \(reason)")
        XCTAssertTrue(reason.hasSuffix("Nothing was written."), reason)
    }

    func testTheOccurrenceDateRefusalNamesBothWays() {
        let reason = DetachedOccurrenceSpan.occurrenceDateReason
        XCTAssertTrue(reason.contains("occurrence_date is another day"), reason)
        XCTAssertTrue(reason.contains("that occurrence's own id from list_events"), reason)
        XCTAssertTrue(reason.contains("leave occurrence_date out"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was changed."), reason)
    }

    /// #416 measured that the occurrence which comes first reaches the series through its own id,
    /// so the hint for a bare id says so, in words a batch caller can use too.
    func testTheEditedBeforeHintsNameTheOwnIdRoute() {
        for text in [EventKitManager.standInEditedBeforeReason, EventKitManager.standInEditedBeforeBatchReason] {
            XCTAssertTrue(text.contains("The occurrence that comes first in the series reaches it through its own id: update_event with span 'all', delete_event with span 'future'."), text)
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
        XCTAssertTrue(head.contains("if let refusal = DetachedOccurrenceSpan.updateRefusal( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, neighbours: occurrenceNeighbours(of: masterEvent, id: identifier)) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), head)
    }

    /// Before the first field is assigned, as #373 requires of every refusal.
    func testTheOtherRefusalsOfAnUpdateComeBeforeTheFirstAssignment() throws {
        let body = try updateBody()
        XCTAssertTrue(body.contains("if DetachedOccurrenceSpan.refusesSeriesProperty( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, span: span, changesAccount: crossesAccounts, clearsRecurrence: clearRecurrence) { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.seriesPropertyReason) }"), body)
        XCTAssertTrue(body.contains("DetachedOccurrenceSpan.refusesOccurrenceDate( identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll, hasOccurrenceDate: occurrenceDate != nil, matches: occurrenceDateMatches(occurrenceDate, occurrence: masterEvent, id: identifier))"), body)
    }

    /// `event.recurrenceRules` is nil on the detached object, so the weekday check reads the series'.
    func testTheWeekdayCheckReadsTheSeriesRulesThroughAnOccurrence() throws {
        let body = try updateBody()
        XCTAssertTrue(body.contains("let rulesForWeekday = masterEvent.isDetached && (applyToAll || span != .thisEvent) ? seriesObject(ofOccurrence: identifier)?.recurrenceRules : event.recurrenceRules"), body)
        XCTAssertTrue(body.contains("let rules = rulesForWeekday,"), body)
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
        XCTAssertTrue(body.contains("coversWholeSeries: DetachedOccurrenceSpan.coversWholeSeries( rules: (series.recurrenceRules ?? []).map(DetachedOccurrenceSpan.RuleExtent.init), firstStart: firstStart, scannedTo: scannedTo, calendar: Calendar.current)"), body)
    }

    func testTheSeriesDeletesCheckBeforeTheyRemove() throws {
        let single = try collapsed("func deleteEventSeries(identifier: String)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(single.contains("if let refusal = seriesDeleteRefusal(event, id: identifier) { throw EventKitError.occurrenceAddressRefused(reason: refusal) }"), single)
        let batch = try collapsed("func deleteEventSeriesBatch(identifiers: [String], refusingOccurrenceIdentifiers: Bool)", upTo: "eventStore.remove(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(batch.contains("if refusingOccurrenceIdentifiers, let refusal = seriesDeleteRefusal(event, id: id, namedInTheCall: Set(identifiers), batch: true) { failures.append((id, refusal)) continue }"), batch)
    }

    /// The preview by `event_ids` does not list what the real call refuses, for span all only.
    func testTheDryRunByEventIdsUsesTheRefusal() throws {
        let source = SourceScan.strippingComments(try SourcePins.source("Server.swift"))
        let batch = try XCTUnwrap(source.range(of: "private func handleDeleteEventsBatch("))
        let rest = source[batch.upperBound...]
        let until = try XCTUnwrap(rest.range(of: "\"start_date_local\""))
        let preview = SourceScan.collapsingWhitespace(String(rest[..<until.lowerBound]))
        XCTAssertTrue(preview.contains("if spanStr == \"all\", let refusal = await eventKitManager.seriesDeleteRefusal(identifier: id, namedInTheCall: Set(eventIds)) { preview.append([\"event_id\": id, \"error\": refusal]) continue }"), preview)
    }
}
