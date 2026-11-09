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
                                    + "movesStart:!UndoPostState.sameInstant(shiftStart,event.startDate),changesZone:changesZone,"
                                    + "changesAllDay:datePlan.isAllDay!=event.isAllDay)"))
        XCTAssertFalse(code.contains("repeats:event.hasRecurrenceRules"))
        XCTAssertTrue(code.contains("letruleHolder:EKEvent?=addressesOwnOccurrence?tryseriesObject(ofOccurrence:identifier):event"))
        XCTAssertTrue(code.contains("storedStarts:addressesOwnOccurrence?[event.startDate,eventSlot]:[event.startDate]"))
        // MEDIUM 6: a passed rule is checked against its own end; MEDIUM 7: the rule's unit.
        XCTAssertTrue(code.contains("passedRule:RuleEndShift.passedRule(recurrenceRule,clearing:clearRecurrence)"))
        XCTAssertTrue(code.contains("unit:RuleEndShift.unit(of:rules)"))
        // LOW 8; round 2 LOW 6: through an occurrence's own id the route is Calendar (#416).
        XCTAssertTrue(code.contains("from:applyToAll?nil:eventSlot,"))
        XCTAssertTrue(code.contains("route:RuleEndShift.route(ruleWritable:SeriesRuleWrite.writableRule(seriesRules)!=nil,addressesOwnOccurrence:addressesOwnOccurrence,"
                                    + "keepsDays:plan.keepsDays,endedAfterHappening:happened&&storedEnds.contains{$0<now}))"))
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
        // The order of the decision (round 2): all-day, past the end, over a year, listing, placing.
        let source2 = try SourcePins.source("EventKit/RuleEndShift.swift")
        let decision = flat(try XCTUnwrap(SourcePins.body(of: "static func refusal(", in: source2)))
        let steps = ["ifallDay{returnuncheckedReason(.allDay)}", "ifnearMonthEnd(plan){returnuncheckedReason(.monthEnd)}", "ifstartsPastEnd(", "ifexceedsMaxShift(plan){returnuncheckedReason(.tooFar)}",
                     "guardletlisted=list(range)else{returnuncheckedReason(.unlisted)}", "iflisted.isEmpty{returnuncheckedReason(.empty)}", "guardletslots=place(listed)else{returnuncheckedReason(.unplaced)}"]
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
