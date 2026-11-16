import XCTest
@testable import CheICalMCP

/// #484: the wiring of "older undo records follow a calendar change made through `update_event`".
/// No unit test can give an in-memory event a new identifier, so the rule is tested as a value
/// (`EventUpdateRecordTests`) and the three call sites are pinned here in source: `updateEvent`
/// after its save, the undo of a one-off's update, and (in `UndoKeepLaterEditsWiringTests`) the
/// `keep_later_edits` arm. The behaviour itself rests on the device runs listed on the issue.
final class EventUpdateFollowWiringTests: XCTestCase {
    private static let manager = "EventKit/EventKitManager.swift"

    private func updateEventBody() throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: try SourcePins.source(Self.manager))))
    }

    /// The `.updateEvent` arm of `executeUndo`: from its case to the next one.
    private func updateUndoArm() throws -> String {
        let body = SourceScan.collapsingWhitespace(try XCTUnwrap(
            SourcePins.body(of: "func executeUndo(_ operation: UndoOperation) async throws -> String", in: try SourcePins.source(Self.manager))))
        let start = try XCTUnwrap(body.range(of: "case .updateEvent(let recordedID, let oldSnapshot, _):"), "the arm binds the record's identifier")
        let end = try XCTUnwrap(body.range(of: "case .updateRecurringEvent(", range: start.upperBound..<body.endIndex))
        return String(body[start.lowerBound..<end.lowerBound])
    }

    private func assertOnce(_ needle: String, in body: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SourcePins.ranges(of: needle, in: body).count, 1, "exactly one \(needle)", file: file, line: line)
    }

    private func assertOrder(_ needles: [String], in body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var last = body.startIndex
        for needle in needles {
            let range = try XCTUnwrap(body.range(of: needle, range: last..<body.endIndex), "\(needle) after the previous step", file: file, line: line)
            last = range.upperBound
        }
    }

    /// Read once, before the first field of the event is assigned: read after the calendar was
    /// assigned it would be false for every call, and the forward rewrite would never run.
    func testTheCalendarChangeIsReadOnceBeforeTheFirstAssignment() throws {
        let body = try updateEventBody()
        let declaration = "let changesCalendar = newCalendar.map { $0.calendarIdentifier != event.calendar?.calendarIdentifier } ?? false"
        assertOnce(declaration, in: body)
        assertOnce("newCalendar.map { $0.calendarIdentifier != event.calendar?.calendarIdentifier } ?? false", in: body)
        let ownID = "let ownOccurrenceID = DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: masterEvent.isDetached)"
        assertOnce(ownID, in: body)
        try assertOrder([declaration, "if let t = title { event.title = t }", "event.calendar = newCalendar", "try eventStore.save(event, span: span)"], in: body)
        try assertOrder([ownID, "if let t = title { event.title = t }"], in: body)
        // The two refusals that computed the same expression read the one value.
        XCTAssertEqual(SourcePins.ranges(of: "changesCalendar: changesCalendar", in: body).count, 2, "refusesCalendarOnOccurrence and laterOccurrenceRefusal")
    }

    /// After the save and before the update's own record, with these exact facts.
    func testTheForwardRewriteComesAfterTheSaveWithTheFiveFacts() throws {
        let body = try updateEventBody()
        let ask = "if let followed = EventUpdateRecord.identifierToFollow( requestedID: identifier, identifierAfterSave: event.eventIdentifier, changedCalendar: changesCalendar, wholeEvent: !hadRules || applyToAll, viaStandIn: resolved.viaStandIn, ownOccurrenceID: ownOccurrenceID) {"
        assertOnce(ask, in: body)
        assertOnce("EventUpdateRecord.identifierToFollow(", in: body)
        try assertOrder(["try eventStore.save(event, span: span)", ask,
                         "await CalendarUndoManager.shared.replaceEventIdentifier(identifier, with: followed)",
                         "await CalendarUndoManager.shared.record(EventUpdateRecord.operation("], in: body)
    }

    /// spec-example: undo-history-discard / the saved object is picked in three branches
    /// `wholeEvent` is `!hadRules || applyToAll`, which means "the saved object is the one the
    /// identifier resolved to" only while these three branches stay as they are. Object identity is
    /// not asked: whether a picked occurrence is ever the resolved instance is the store's business.
    func testTheSavedObjectIsPickedInThreeBranches() throws {
        let body = try updateEventBody()
        assertOnce("let hadRules = masterEvent.hasRecurrenceRules", in: body)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bevent = masterEvent\b"#, in: body).count, 2)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bevent = occurrence\b"#, in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bevent = "#, in: body).count, 3, "no fourth branch picks the saved object")
        try assertOrder(["let hadRules = masterEvent.hasRecurrenceRules",
                         "if !masterEvent.hasRecurrenceRules { event = masterEvent",
                         "} else if applyToAll {", "event = masterEvent",
                         "} else if let date = occurrenceDate {", "event = occurrence",
                         "try eventStore.save(event, span: span)"], in: body)
    }

    /// The undo of a one-off's update: save, then compare the record's identifier with the event's,
    /// rewrite older records, and answer through the text builder. The rewrite is the point: with
    /// only the new ID in the answer the create record under it would still answer not found (M4).
    func testTheUpdateUndoArmFollowsAndReportsAfterItsSave() throws {
        let arm = try updateUndoArm()
        try assertOrder(["oldSnapshot.apply(to: event, calendar: calendar)",
                         "try eventStore.save(event, span: .thisEvent)",
                         "markNeedsRefresh()",
                         "if let restoredID = event.eventIdentifier, CalendarUndoManager.identifierChanged(from: recordedID, to: restoredID) {",
                         "await CalendarUndoManager.shared.replaceEventIdentifier(recordedID, with: restoredID)",
                         "return EventUpdateRecord.updateUndoneText(title: oldSnapshot.title, newID: restoredID)",
                         "return EventUpdateRecord.updateUndoneText(title: oldSnapshot.title, newID: nil)"], in: arm)
        assertOnce("CalendarUndoManager.shared.replaceEventIdentifier(", in: arm)
        // Nothing new suspends between the #236 check and the write: the arm's awaits are the
        // calendar read, the check, and the rewrite after the save.
        let check = try XCTUnwrap(arm.range(of: "try await verifiedEvent(of: operation, verb: .undo)"))
        let save = try XCTUnwrap(arm.range(of: "try eventStore.save(event, span: .thisEvent)"))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bawait\b"#, in: String(arm[check.upperBound..<save.lowerBound])).count, 0)
    }

    /// The five callers, and no sixth: `moveEvent`, the move's undo, `updateEvent`, the update's
    /// undo, and the `keep_later_edits` event arm.
    func testTheRewriteIsCalledFromExactlyFivePlaces() throws {
        var calls: [String: Int] = [:]
        for file in try SourceScan.swiftFiles() {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            let count = SourcePins.ranges(of: "shared.replaceEventIdentifier(", in: code).count
            if count > 0 { calls[file.lastPathComponent] = count }
        }
        XCTAssertEqual(calls, ["EventKitManager.swift": 4, "EventKitManager+KeepLaterEdits.swift": 1])
    }
}
