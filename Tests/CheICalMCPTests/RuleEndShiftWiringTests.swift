import XCTest

/// #509: the rule-end check reads the store, which an in-memory store cannot run, so its wiring in
/// `updateEvent` is pinned over the source. Its order before the first write is pinned by
/// `UpdateEventRefusalOrderTests`.
final class RuleEndShiftWiringTests: XCTestCase {
    private func flat(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    func testUpdateEventChecksTheRuleEndForEveryStartMoveOverTheRestOfASeries() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let code = flat(body)
        // PR #510 round 1 (HIGH 2): gated on the series' rules, so the own-id routes are checked.
        XCTAssertTrue(code.contains("repeats:RuleEndShift.repeats(masterHasRules:masterEvent.hasRecurrenceRules,addressesOwnOccurrence:addressesOwnOccurrence),"
                                    + "reachesEnd:applyToAll||span==.futureEvents,"
                                    + "movesStart:RuleEndShift.mayMoveStart(planned:shiftStart,from:[event.startDate,eventSlot],"
                                    + "writesDates:datePlan.datesToWrite!=nil,firstSlotUnread:wholeThroughSeries),changesZone:changesZone,"
                                    + "changesAllDay:datePlan.isAllDay!=event.isAllDay)"))
        XCTAssertTrue(code.contains("letwholeThroughSeries=applyToAll&&!addressesOwnOccurrence"))
        XCTAssertFalse(code.contains("repeats:event.hasRecurrenceRules"))
        XCTAssertTrue(code.contains("letruleHolder:EKEvent?=addressesOwnOccurrence?tryseriesObject(ofOccurrence:identifier):event"))
        // Round 5 (MEDIUM): every route reads the shown start and the slot; through the series id over the
        // whole series also the first slot as #503 proves it, refused when it cannot be shown, and only
        // where an end is checked (an open series is not refused).
        XCTAssertFalse(code.contains("storedStarts:addressesOwnOccurrence?[event.startDate,eventSlot]:[event.startDate]"))
        // PR #518 round 1: also where #513's month-end check of a series with no end can apply.
        XCTAssertTrue(code.contains("letendsChecked=!RuleEndShift.ends(stored:storedEnds,passedRule:passedRule).isEmpty"))
        XCTAssertTrue(code.contains("letneedsFirstSlot=RuleEndShift.needsFirstSlot(wholeThroughSeries:wholeThroughSeries,endsChecked:endsChecked,"
                                    + "monthEndShape:RuleEndShift.monthEndShape(unit:unit,dayFromStart:dayFromStart,passedRule:passedRule))"))
        XCTAssertTrue(code.contains("letfirstSlot:Date?=needsFirstSlot?wholeSeriesBaseline(of:masterEvent,id:identifier,viaStandIn:resolved.viaStandIn).slot:nil"))
        XCTAssertTrue(code.contains("guardletstoredStarts=RuleEndShift.storedStarts(shown:event.startDate,slot:eventSlot,needsFirstSlot:needsFirstSlot,"
                                    + "firstSlot:firstSlot)else{throwEventKitError.seriesWriteRefused(reason:endsChecked?RuleEndShift.uncheckedReason(.firstSlot):RuleEndShift.openFirstSlotReason)}"))
        XCTAssertTrue(code.contains("ifRuleEndShift.moves(planned:shiftStart,from:storedStarts)||changesZone||datePlan.isAllDay!=event.isAllDay{"))
        XCTAssertTrue(code.contains("letplan=RuleEndShift.Plan(storedStarts:storedStarts,"))
        // MEDIUM 6: a passed rule is checked against its own end; MEDIUM 7: the rule's unit.
        XCTAssertTrue(code.contains("letpassedRule=RuleEndShift.passedRule(recurrenceRule,clearing:clearRecurrence)"))
        XCTAssertTrue(code.contains("storedEnds:storedEnds,passedRule:passedRule,plan:plan,"))
        // #513: a rule passed in the call counts for the unit (the coarser) and the day.
        XCTAssertTrue(code.contains("letunit=RuleEndShift.coarser(RuleEndShift.unit(of:rules),passedUnit)"))
        XCTAssertTrue(code.contains("letdayFromStart=parts.contains{!$0.fixesDay}||passedTakesDayFromStart"))
        XCTAssertTrue(code.contains("plannedStart:shiftStart,storedZone:storedZone,newZone:newZone,unit:unit,"))
        XCTAssertTrue(code.contains("letpassedUnit=recurrenceRule.map{RuleEndShift.unit(of:$0.frequency)}"))
        XCTAssertTrue(code.contains("letpassedTakesDayFromStart=recurrenceRule.map{!RuleEndShift.namesDays(daysOfWeek:$0.daysOfWeek,daysOfMonth:$0.daysOfMonth)}??false"))
        // LOW 8; round 2 LOW 6: through an occurrence's own id the route is Calendar (#416).
        XCTAssertTrue(code.contains("from:applyToAll?nil:eventSlot,"))
        XCTAssertTrue(code.contains("route:RuleEndShift.route(ruleWritable:SeriesRuleWrite.writableRule(seriesRules)!=nil,addressesOwnOccurrence:addressesOwnOccurrence,"
                                    + "viaStandIn:resolved.viaStandIn,keepsDays:plan.keepsDays,startsAgree:RuleEndShift.startsAgree(storedStarts),"
                                    + "endedAfterHappening:happened&&storedEnds.contains{$0<now}))"))
        // Round 2 LOW 7: an all-day series, before or after the write, is not checked and refused.
        XCTAssertTrue(code.contains("allDay:event.isAllDay||datePlan.isAllDay||holder.isAllDay,"))
        XCTAssertTrue(code.contains("throwEventKitError.seriesWriteRefused(reason:reason)"))
        XCTAssertTrue(code.contains("letstoredZone:TimeZone=event.isAllDay?.current:(event.timeZone??.current)"))
        XCTAssertTrue(code.contains("letnewZone:TimeZone=datePlan.isAllDay||clearTimezone?.current:(timezone??event.timeZone??.current)"))
    }

    /// HIGH 2: the series-id route whose first occurrence was edited on its own (#428) goes back into
    /// updateEvent with that occurrence's own id, so it takes the own-id gate above.
    /// Round 2 HIGH 1: on a series known to repeat, no series object or no rules read refuses before
    /// the plan and the ends are read, instead of reading as a rule with no end.
    func testRulesThatCannotBeReadRefuseBeforeThePlan() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let code = flat(body)
        let guardText = "guardletholder=ruleHolder,letrules=RuleEndShift.readRules(holder.recurrenceRules)else{"
            + "throwEventKitError.seriesWriteRefused(reason:RuleEndShift.uncheckedReason(.unreadable))}"
        let read = try XCTUnwrap(code.range(of: guardText))
        let plan = try XCTUnwrap(code.range(of: "letplan=RuleEndShift.Plan("))
        XCTAssertLessThan(read.lowerBound, plan.lowerBound)
        XCTAssertFalse(code.contains("ruleHolder?.recurrenceRules??[]"))
        // Round 4 (HIGH): the day comes from the rule's parts, apart from whether it has BY parts.
        XCTAssertTrue(code.contains("letparts=rules.map(RuleEndShift.parts)"))
        XCTAssertTrue(code.contains("keepsDays:parts.contains{$0.fixesDay},dayFromStart:dayFromStart,"
                                    + "expandable:parts.allSatisfy{$0.expandable},weeklyDays:RuleEndShift.weeklyDays(rules))"))
    }

    func testTheSeriesIdRouteThroughAnEditedFirstOccurrenceReentersTheCheck() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let code = flat(body)
        XCTAssertTrue(code.contains("saved=tryawaitupdateEvent(identifier:first.id,"))
        let recursion = try XCTUnwrap(code.range(of: "saved=tryawaitupdateEvent(identifier:first.id,"))
        let gate = try XCTUnwrap(code.range(of: "RuleEndShift.applies("))
        XCTAssertLessThan(recursion.lowerBound, gate.lowerBound, "the recursion runs the whole body, the gate included")
    }

    func testTheListingKeepsOnlyTheSeriesOwnSlotsAndFailsClosed() throws {
        let source = try SourcePins.source("EventKit/EventKitManager+RuleEndShift.swift")
        let body = flat(try XCTUnwrap(SourcePins.body(of: "func ruleEndShiftRefusal(", in: source)))
        XCTAssertTrue(body.contains("guardUndoPostState.isOccurrence(occurrence,of:ids)else{returnnil}"))
        XCTAssertTrue(body.contains("UndoPostState.ruleSlot("), "an edited occurrence counts by its original slot")
        // HIGH 1: a series or calendar that cannot be read lists nothing, which refuses (`RuleEndShift.refusal`).
        XCTAssertTrue(body.contains("guardletseriesID,letcalendar=series.calendar,"))
        XCTAssertTrue(body.contains("letlisted=try?events(from:range.start,to:range.end,calendars:[calendar])else{returnnil}"))
        XCTAssertTrue(body.contains("RuleEndShift.refusal("))
        // The order of the decision (round 5): all-day, unexpandable, month end, over a year, listing, placing, past the end.
        let source2 = try SourcePins.source("EventKit/RuleEndShift.swift")
        let decision = flat(try XCTUnwrap(SourcePins.body(of: "static func refusal(", in: source2)))
        // Round 5 (LOW): a start past the end is decided after the move's size and the listing, so it never
        // offers the recurrence route where a retry meets one of those causes.
        let steps = ["ifallDay{returnuncheckedReason(.allDay)}", "if!plan.expandable{returnuncheckedReason(.unexpandable)}", "ifnearMonthEnd(plan){returnuncheckedReason(.monthEnd)}", "ifexceedsMaxShift(plan){returnuncheckedReason(.tooFar)}",
                     "guardletlisted=list(range)else{returnuncheckedReason(.unlisted)}", "iflisted.isEmpty{returnuncheckedReason(.empty)}", "guardletslots=place(listed)else{returnuncheckedReason(.unplaced)}", "ifstartsPastEnd("]
        // #513: with no end, only the month-end shape refuses, before the other steps.
        XCTAssertTrue(decision.contains("guard!ends.isEmptyelse{returnpassedRule!=.clear&&nearMonthEnd(plan)?openMonthEndReason:nil}"))
        let found = try steps.map { try XCTUnwrap(decision.range(of: $0), $0).lowerBound }
        XCTAssertEqual(found, found.sorted())
    }

    func testTheDocumentsNameTheRefusalAndTheRoute() throws {
        let server = try SourcePins.source("Server.swift")
        let phrase = "pass the series' rule in the same call as recurrence, with an end_date at or after the occurrence's new start"
        XCTAssertEqual(server.components(separatedBy: phrase).count - 1, 1, phrase)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for document in ["README.md", "README_zh-TW.md", "CHANGELOG.md", "mcpb/manifest.json"] {
            let text = try String(contentsOf: root.appendingPathComponent(document), encoding: .utf8)
            XCTAssertTrue(text.contains("#509"), document)
        }
    }
}
