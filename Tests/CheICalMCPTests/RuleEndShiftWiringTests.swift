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
                                    + "movesStart:!UndoPostState.sameInstant(shiftStart,event.startDate),changesZone:changesZone)"))
        XCTAssertFalse(code.contains("repeats:event.hasRecurrenceRules"))
        XCTAssertTrue(code.contains("letruleHolder:EKEvent?=addressesOwnOccurrence?tryseriesObject(ofOccurrence:identifier):event"))
        XCTAssertTrue(code.contains("storedStarts:addressesOwnOccurrence?[event.startDate,eventSlot]:[event.startDate]"))
        // MEDIUM 6: a passed rule is checked against its own end; MEDIUM 7: the rule's unit.
        XCTAssertTrue(code.contains("passedRule:RuleEndShift.passedRule(recurrenceRule,clearing:clearRecurrence)"))
        XCTAssertTrue(code.contains("unit:RuleEndShift.unit(of:rules)"))
        // LOW 8, LOW 9.
        XCTAssertTrue(code.contains("from:applyToAll?nil:eventSlot,ruleWritable:SeriesRuleWrite.writableRule(seriesRules)!=nil)"))
        XCTAssertTrue(code.contains("throwEventKitError.seriesWriteRefused(reason:reason)"))
        XCTAssertTrue(code.contains("letstoredZone:TimeZone=event.isAllDay?.current:(event.timeZone??.current)"))
        XCTAssertTrue(code.contains("letnewZone:TimeZone=datePlan.isAllDay||clearTimezone?.current:(timezone??event.timeZone??.current)"))
    }

    /// HIGH 2: the series-id route whose first occurrence was edited on its own (#428) goes back into
    /// updateEvent with that occurrence's own id, so it takes the own-id gate above.
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
        // HIGH 1: an unplaceable or empty listing refuses; MEDIUM 3: a capped range, refused early past the end.
        XCTAssertTrue(body.contains("guardletslots=RuleEndShift.place(own)else{returnRuleEndShift.unknownReason(ruleWritable:ruleWritable)}"))
        XCTAssertTrue(body.contains("guardletrange=RuleEndShift.listingRange(ruleEnd:ruleEnd,plan:plan),"))
        XCTAssertTrue(body.contains("letlisted=try?events(from:range.start,to:range.end,calendars:[calendar])else{"))
        XCTAssertTrue(body.contains("ifRuleEndShift.startsPastEnd(plannedStart:plan.plannedStart,ruleEnd:ruleEnd){"))
        XCTAssertEqual(SourcePins.ranges(of: "returnRuleEndShift.unknownReason(ruleWritable:ruleWritable)", in: body).count, 3)
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
