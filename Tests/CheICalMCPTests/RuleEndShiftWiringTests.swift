import XCTest

/// #509: the rule-end check reads the store, which an in-memory store cannot run, so its wiring in
/// `updateEvent` is pinned over the source. Its order before the first write is pinned by
/// `UpdateEventRefusalOrderTests`.
final class RuleEndShiftWiringTests: XCTestCase {
    private func flat(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    func testUpdateEventChecksTheRuleEndForEveryStartMoveOverTheRestOfASeries() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let code = flat(body)
        XCTAssertTrue(code.contains("RuleEndShift.applies(repeats:event.hasRecurrenceRules,reachesEnd:applyToAll||span==.futureEvents,"
                                    + "writesRule:recurrenceRule!=nil||clearRecurrence,storedStart:event.startDate,"
                                    + "plannedStart:datePlan.datesToWrite?.start)"))
        XCTAssertTrue(code.contains("ruleEndShiftRefusal(series:ruleHolder,seriesID:seriesID,storedStart:event.startDate,"
                                    + "plannedStart:plannedStart,storedZone:storedZone,newZone:newZone)"))
        XCTAssertTrue(code.contains("throwEventKitError.seriesWriteRefused(reason:reason)"))
        // The zones the event has before and after the write.
        XCTAssertTrue(code.contains("letstoredZone:TimeZone=event.isAllDay?.current:(event.timeZone??.current)"))
        XCTAssertTrue(code.contains("letnewZone:TimeZone=datePlan.isAllDay||clearTimezone?.current:(timezone??event.timeZone??.current)"))
    }

    func testTheListingKeepsOnlyTheSeriesOwnSlotsAndFailsClosed() throws {
        let source = try SourcePins.source("EventKit/EventKitManager+RuleEndShift.swift")
        let body = flat(try XCTUnwrap(SourcePins.body(of: "func ruleEndShiftRefusal(", in: source)))
        XCTAssertTrue(body.contains("guardUndoPostState.isOccurrence(occurrence,of:ids)else{returnnil}"))
        XCTAssertTrue(body.contains("UndoPostState.originalSlot("))
        // No series, no calendar, or a listing that fails: refused, not passed.
        XCTAssertEqual(SourcePins.ranges(of: "returnRuleEndShift.unknownReason", in: body).count, 2)
        XCTAssertTrue(body.contains("guardletlisted=try?events(from:window.start,to:window.end,calendars:[calendar])else{"))
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
