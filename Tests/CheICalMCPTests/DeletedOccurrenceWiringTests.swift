import XCTest
@testable import CheICalMCP

/// #503: the deleted-occurrence refusal in `updateEvent` reads the store, so no unit test runs it.
/// It runs after #442's all_day refusal and before the first field of the event is assigned
/// (#373: a refusal after an assignment leaves the rejected values on the cached object), and it
/// reads the series' listing the way #442 does.
final class DeletedOccurrenceWiringTests: XCTestCase {
    func testTheRefusalRunsBeforeTheFirstAssignment() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        let allDay = try XCTUnwrap(update.range(of: "DetachedOccurrenceSpan.refusesAllDayChange("))
        let applies = try XCTUnwrap(update.range(of: "DeletedOccurrenceCheck.applies("))
        let verdict = try XCTUnwrap(update.range(of: "deletedOccurrenceVerdict("))
        let first = try XCTUnwrap(update.range(of: "if let t = title { event.title = t }"))
        XCTAssertLessThan(allDay.lowerBound, applies.lowerBound)
        XCTAssertLessThan(applies.lowerBound, verdict.lowerBound)
        XCTAssertLessThan(verdict.lowerBound, first.lowerBound)
        XCTAssertTrue(update.contains("reachesSeveral: reach.isWholeSeries || reach.isFromLaterOccurrence"))
        // PR #505 round 1: a whole-series write filters no slot, and a stand-in is passed as such.
        // PR #505 round 6 (LOW 6): across accounts every slot is checked, not only those from the anchor on.
        XCTAssertTrue(update.contains("reachedFrom: crossesAccounts ? nil : DeletedOccurrenceCheck.reachedFrom(isWholeSeries: reach.isWholeSeries, anchor: reach.anchor)"))
        XCTAssertTrue(update.contains("let viaStandInForCheck = addressesOwnOccurrence ? false : resolved.viaStandIn"))
        XCTAssertTrue(update.contains("viaStandIn: viaStandInForCheck,"))
        // PR #505 round 2: a zone change is checked (measured), and the route facts are passed.
        XCTAssertTrue(update.contains("resultAllDay: datePlan.isAllDay, storedAllDay: event.isAllDay, changesZone: changesZone, changesAccount: changesAccount,"))
        XCTAssertTrue(update.contains("changesPattern: changesPattern, baseline: baseline)"))
        XCTAssertTrue(update.contains("changesAllDay: datePlan.isAllDay != event.isAllDay"))
        XCTAssertTrue(update.contains("if addressesOwnOccurrence { _ = series?.refresh() }"))
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.deletedReason"))
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.unknownReason"))
        // PR #505 round 4 (MEDIUM): a calendar of another account goes through the same verdict.
        XCTAssertTrue(update.contains("if deletedOccurrenceCheckApplies(changesAccount: crossesAccounts, baseline: baseline) {"))
        XCTAssertTrue(update.contains("let onlyTheAccount = !deletedOccurrenceCheckApplies(changesAccount: false, baseline: baseline)"))
        // PR #505 round 5 (MEDIUM): a whole-series write of the stored dates takes its baseline from the
        // listing, so a first occurrence edited on its own makes any date in the call checked.
        XCTAssertTrue(update.contains("if reach.isWholeSeries, datePlan.datesToWrite != nil {"))
        let proof = "let proof = try seriesForCheck().map { wholeSeriesBaseline(of: $0.0, id: $0.1, viaStandIn: viaStandInForCheck) }"
        XCTAssertTrue(update.contains(proof))
        // Round 6 (LOW 5): the start counts as changed against the proven slot only.
        XCTAssertTrue(update.contains("startChanges: DeletedOccurrenceCheck.startChanges(planned: datePlan.datesToWrite?.start, provenSlot: provenSlot)"))
        XCTAssertTrue(update.contains("changesZone: changesZone, changesPattern: changesPattern, changesAccount: crossesAccounts)"))
        // Round 5 (LOW): a rule with another pattern is checked; each refusal names its cause and kind.
        // Round 6 (LOW 4): every stored rule of the series object, and its first slot's weekday and day.
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.changesPattern(DeletedOccurrenceCheck.Rule($0), stored: (rulesSeries?.recurrenceRules ?? []).map(DeletedOccurrenceCheck.Rule.init),"))
        XCTAssertTrue(update.contains("startWeekday: seriesFirstSlotDay?.weekday, startDay: seriesFirstSlotDay?.day)"))
        XCTAssertTrue(update.contains(".dateComponents([.weekday, .day], from: $0.occurrenceDate ?? $0.startDate)"))
        XCTAssertFalse(update.contains("storedStartWeekday"), "the shown start's weekday is not used")
        XCTAssertTrue(update.contains("case .unknown(let cause): throw EventKitError.seriesWriteRefused(reason: DeletedOccurrenceCheck.unknownReason(cause))"))
        // PR #505 round 7 (MEDIUM 1, LOW 5): the route block knows the account and the first occurrence's own id.
        XCTAssertTrue(update.contains("let route = DeletedOccurrenceCheck.refusalRoute(blocked, crossesAccounts: crossesAccounts, throughFirstOwnID: DetachedOccurrenceSpan.addressesFirstBySlot(ownNeighbours))"))
        XCTAssertTrue(update.contains("DeletedOccurrenceCheck.deletedReason(blocked: route, change: change)"))
        XCTAssertTrue(update.contains("case _ where onlyTheAccount: throw EventKitError.seriesWriteRefused(reason: DeletedOccurrenceCheck.accountMoveReason(verdict, fromLaterOccurrence: reach.isFromLaterOccurrence))"))
    }

    /// PR #505 round 4 (MEDIUM): `move_events_batch` of a whole series to another account checks the
    /// series before anything is written.
    func testAMoveToAnotherAccountChecksTheSeriesFirst() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let move = try XCTUnwrap(SourcePins.body(of: "func moveEvent(", in: manager))
        let check = try XCTUnwrap(move.range(of: "deletedOccurrenceVerdict(of: series, id: seriesID, reachedFrom: nil,"))
        let firstWrite = try XCTUnwrap(move.range(of: "EventMoveExecutor.run("))
        XCTAssertLessThan(check.lowerBound, firstWrite.lowerBound)
        XCTAssertTrue(move.contains("if isRecurring, !(span == .this && occurrenceDate != nil),"))
        XCTAssertTrue(move.contains("FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: master.calendar?.source?.sourceIdentifier,"))
        // #506 verify r1 (item 10): an exhaustive switch replaced `if verdict != .none {`.
        XCTAssertTrue(move.contains("switch verdict {"))
        XCTAssertTrue(move.contains("throw EventKitError.moveRefused(reason: DeletedOccurrenceCheck.accountMoveReason(verdict))"))
        // PR #505 round 5 (INFO 6): a malformed call answers with its argument error, before the
        // series is listed.
        let arguments = try XCTUnwrap(move.range(of: "EventMovePolicy.argumentRefusal(isRecurring: isRecurring, span: span, hasOccurrenceDate: occurrenceDate != nil)"))
        XCTAssertLessThan(arguments.lowerBound, check.lowerBound)
    }

    /// PR #505 round 5 (MEDIUM): the baseline reads the first occurrence at the series' start the way
    /// the verdict does, and an edited one, or a slot not shown, is unproven.
    func testTheBaselineReadsTheFirstOccurrence() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "func wholeSeriesBaseline(", in: file))
        XCTAssertTrue(body.contains("guard let (_, candidates) = seriesOccurrences(of: series, id: id), !candidates.isEmpty else { return (.unproven, nil) }"))
        XCTAssertTrue(body.contains("let atStart = candidates.filter { UndoPostState.sameInstant($0.start, series.startDate) }"))
        XCTAssertTrue(body.contains("return (DeletedOccurrenceCheck.baseline(firstSlot: slot, firstIsEdited: atStart.first?.isDetached ?? true, startDate: series.startDate), slot)"))
    }

    func testTheVerdictListsTheSeriesAsTheAllDayCheckDoes() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "func deletedOccurrenceVerdict(", in: file))
        // #506: the listing ranges come from the horizon helper, which returns #442's ranges when no horizon is given
        // or they reach it (DeletedOccurrenceHorizonTests.testAYoungSeriesIsListedAsBefore).
        XCTAssertTrue(body.contains("seriesOccurrences(of: series, id: id, ranges: ranges)"))
        XCTAssertTrue(body.contains("DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now ?? Date(), rules: extents,"))
        // #506 verify r1: coverage through `DeletedOccurrenceCheck.coversWholeSeries(ranges:)`, which wraps #442's.
        XCTAssertTrue(body.contains("DeletedOccurrenceCheck.coversWholeSeries("))
        XCTAssertTrue(body.contains("UndoPostState.ruleSlot(of:"), "edited occurrences count by their rule slot")
        XCTAssertTrue(body.contains("DeletedOccurrenceCheck.firstSlotResult("), "the first slot is proven, never taken from a stand-in")
        XCTAssertTrue(body.contains("firstSlotCause: firstSlotCause, listed: ranges, horizon: horizon)"), "the cause reaches the verdict (round 5)")
        XCTAssertTrue(body.contains("let atStart = candidates.filter { UndoPostState.sameInstant($0.start, series.startDate) }"),
                      "every occurrence at the object's own start is counted (round 3: it must be one)")
        XCTAssertTrue(body.contains("earliestListedSlot: candidates.map(ruleSlot).min()"))
        XCTAssertTrue(body.contains("uneditedSlots: candidates.filter { !$0.isDetached }.map(ruleSlot)"))
        XCTAssertTrue(body.contains("slotsTrusted: !candidates.contains { $0.isDetached && !$0.slotFromRID }"))
        XCTAssertTrue(body.contains("guard !candidates.isEmpty else { return .unknown(.notListed) }"), "an empty listing is not 'none deleted'")
        // PR #505 round 4 (LOW 4, 7): an all-day series' end is read with its all-day flag.
        XCTAssertTrue(body.contains("isAllDay: series.isAllDay, firstSlotCause: firstSlotCause, listed: ranges, horizon: horizon)"))
    }

    /// PR #505 round 6 (LOW 8): the start_time description's list names the conditions the check
    /// refuses on that round 4 and 5 added.
    func testTheStartTimeDescriptionNamesTheLaterConditions() throws {
        let server = try SourcePins.source("Server.swift")
        for part in [// #506 verify r1 (item 6): the list now ends with the expansion cap.
                     "or the series is all-day and its rule ends less than a day after an occurrence's start, or its rule gives more than 20,000 occurrences before the end of the listing), since it brought deleted occurrences back (#503).",
                     "dates written over the whole series that equal the shown times of a first occurrence edited on its own",
                     "a recurrence with another pattern (frequency, interval, days or count) over more than one occurrence (not measured)."] {
            XCTAssertEqual(SourcePins.ranges(of: part, in: server).count, 1, part)
        }
    }
}

/// #511: the undo of a whole-series move across accounts goes through #503's verdict inside the #236
/// comparison, which the move arm passes before it writes, after the fields come back empty,
/// and its refusal keeps the record (not `UnrecoverableUndoError`).
final class SeriesMoveUndoAccountWiringTests: XCTestCase {
    func testTheCheckRunsInTheComparisonBeforeTheMoveArmWrites() throws {
        let guardFile = SourcePins.code(try SourcePins.source("EventKit/EventKitManager+UndoGuard.swift"))
        let target = try XCTUnwrap(SourcePins.body(of: "func verifiedHistoryTarget(", in: guardFile))
        let fields = try XCTUnwrap(target.range(of: "let fields = keepingLaterEdits?(event, expected.changedFields(in: event)) ?? expected.changedFields(in: event)"))
        let check = try XCTUnwrap(target.range(of: "if fields.isEmpty, let reason = try seriesMoveBackRefusal(operation, expected, event, verb: verb) {"))
        XCTAssertLessThan(fields.lowerBound, check.lowerBound)
        XCTAssertTrue(target.contains("throw EventKitError.moveRefused(reason: reason)"))
        let helper = try XCTUnwrap(SourcePins.body(of: "func seriesMoveBackRefusal(", in: guardFile))
        XCTAssertTrue(helper.contains("SeriesMoveUndo.restoringCalendarID(of: expected)"))
        XCTAssertTrue(helper.contains("FirstRemainingOccurrence.movesAcrossAccounts("))
        // PR #516 round 1: a calendar lookup miss counts as across (nil source), not as no check.
        XCTAssertTrue(helper.contains("toSourceID: original?.source?.sourceIdentifier"))
        // Round 1: an occurrence's own id lists the series behind it (#426), as the forward move does.
        XCTAssertTrue(helper.contains("SeriesMoveUndo.verdictTarget(id: expected.itemID, isDetached: series.isDetached, resolved: series,"))
        XCTAssertTrue(helper.contains("seriesOf: { try self.seriesObject(ofOccurrence: $0) }"))
        XCTAssertTrue(helper.contains("deletedOccurrenceVerdict(of: target.series, id: target.id, reachedFrom: nil, viaStandIn: false, changesAllDay: false)"))
        XCTAssertTrue(helper.contains("title: expected.title"))
        XCTAssertFalse(helper.contains("UnrecoverableUndoError"))
        // The move arm writes only after verifiedEvent, which runs the comparison.
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let arm = try XCTUnwrap(manager.range(of: "case .moveEvent(let movedID, let fromCalendarIdentifier, _, let title, let isSeries):"))
        let rest = manager[arm.lowerBound...]
        let verified = try XCTUnwrap(rest.range(of: "let event = try await verifiedEvent(of: operation, verb: .undo)"))
        let write = try XCTUnwrap(rest.range(of: "event.calendar = original"))
        XCTAssertLessThan(verified.lowerBound, write.lowerBound)
    }
}
