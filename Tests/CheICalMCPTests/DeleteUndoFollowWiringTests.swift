import XCTest
@testable import CheICalMCP

/// #538: the wiring of "older undo records follow an item the undo of its delete recreated". The
/// rule is tested as a value (`DeleteUndoFollowTests`), the history side on `CalendarUndoManager`
/// (`DeleteUndoFollowHistoryTests`) and the event arm through the handler on an in-memory store
/// (`DeleteUndoFollowHandlerTests`). What only source shows is pinned here: the order in the
/// wrapper, the reminder restore (an in-memory store cannot save a reminder), the arms that pass
/// no identifier, and the call counts.
final class DeleteUndoFollowWiringTests: XCTestCase {
    private static let manager = "EventKit/EventKitManager.swift"
    private static let wrapper = "EventKit/EventKitManager+SeriesExceptions.swift"

    private func body(_ declaration: String, in file: String) throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source(file)), declaration))
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

    private func calls(_ needle: String) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for file in try SourceScan.swiftFiles() {
            let count = SourcePins.ranges(of: needle, in: SourcePins.code(try String(contentsOf: file, encoding: .utf8))).count
            if count > 0 { result[file.lastPathComponent] = count }
        }
        return result
    }

    private var wrapperBody: String {
        get throws { try body("func undoDeletedEvent(_ snapshot: EventSnapshot, removedID: String?, kind: EventRestoreKind = .recreateDeleted) async throws", in: Self.wrapper) }
    }

    /// The arm first, then the decision on what it returned, then the rewrite or the flag; the
    /// source of a move by copy (nil) returns before the decision.
    func testTheWrapperDecidesAfterTheArmReturned() throws {
        let body = try wrapperBody
        try assertOrder(["undone = try await undoDeletedEvent(snapshot, kind: kind, on: store)",
                         "undone = try await undoDeletedEvent(snapshot, kind: kind, on: seriesExceptionsStore)",
                         "guard let removedID else { return (undone.text, undone.outcome) }",
                         "switch DeleteUndoFollow.decision(removedID: removedID, newID: undone.newID, isOccurrenceRecord: snapshot.isOccurrenceRecord, outcome: undone.outcome) {",
                         "case .follow(let newID): await undoHistory.replaceEventIdentifier(removedID, with: newID)",
                         "case .flag(let oneOffs): let flagged = await undoHistory.markSeriesNotFollowed(removedID)",
                         "guard flagged > 0 else { return (undone.text, undone.outcome) }",
                         "return (DeleteUndoFollow.appendingNotFollowed(undone.text, oneOffs: oneOffs), undone.outcome)",
                         "case .none: return (undone.text, undone.outcome)"], in: body)
        assertOnce("DeleteUndoFollow.decision(", in: body)
        let open = try XCTUnwrap(body.firstIndex(of: "{"))
        let guardRange = try XCTUnwrap(body.range(of: "guard let removedID"))
        XCTAssertNil(body.range(of: "removedID", range: body.index(after: open)..<guardRange.lowerBound),
                     "the arm itself is not handed the removed identifier")
    }

    /// The arm hands back the identifier it read after the save and after the exceptions restore.
    func testTheArmReadsTheNewIdentifierAfterTheRestore() throws {
        let body = try body("static func recreateDeletedEvent<Store: SeriesExceptionsStoreSource>(", in: "EventKit/SeriesExceptionsUndo.swift")
        try assertOrder(["return (answer.text, answer.outcome, nil)",
                         "try store.save(event)",
                         "outcome = try restore(exceptions, of: event, in: store)",
                         "let readID = store.identifiers(of: event).eventIdentifier",
                         "let newID = readID.map { DeleteUndoFollow.removedIdentifier(eventIdentifier: $0, hasRules: snapshot.restoresFromRules) }"], in: body)
    }

    /// The record's identifier reaches the wrapper from both delete arms; the move by copy passes nil.
    func testTheArmsPassTheRecordsIdentifier() throws {
        let undo = try body("func executeUndo(_ operation: UndoOperation) async throws -> String", in: Self.manager)
        assertOnce("case .deleteEvent(let removedID, let snapshot):", in: undo)
        assertOnce("return try await undoDeletedEvent(snapshot, removedID: removedID).text", in: undo)
        assertOnce("return .written(try await self.undoDeletedEvent(original, removedID: nil, kind: .undoMoveByCopy).text)", in: undo)
        assertOnce("return Self.restoredReminderMessage(try await restoreDeletedReminder(snapshot, removedID: removedID))", in: undo)
        let member = try body("func undoBatchMember(_ operation: UndoOperation) async throws -> UndoMemberOutcome", in: Self.manager)
        assertOnce("let undone = try await undoDeletedEvent(snapshot, removedID: removedID)", in: member)
        assertOnce("let restored = try await restoreDeletedReminder(snapshot, removedID: removedID)", in: member)
    }

    /// The occurrence arm moves nothing.
    func testTheOccurrenceArmRewritesNothing() throws {
        let body = try body("func undoDeletedOccurrence(_ snapshot: EventSnapshot, notCarriedOver: [String],", in: Self.wrapper)
        for needle in ["replaceEventIdentifier(", "markSeriesNotFollowed(", "replaceReminderIdentifier("] {
            XCTAssertNil(body.range(of: needle), needle)
        }
    }

    /// The reminder is saved, then its older records follow, then the identifier is returned.
    func testTheReminderRestoreFollowsAfterItsSave() throws {
        let body = try body("func restoreDeletedReminder(_ snapshot: ReminderSnapshot, removedID: String) async throws", in: Self.manager)
        try assertOrder(["let storeDiffers = try saveNewReminder(reminder, handler:", "restoring: true)",
                         "let newID = reminder.calendarItemIdentifier",
                         "if let followed = DeleteUndoFollow.reminderIdentifierToFollow(removedID: removedID, newID: newID) {",
                         "await undoHistory.replaceReminderIdentifier(removedID, with: followed)",
                         "return (snapshot.title, storeDiffers, newID)"], in: body)
    }

    /// `handleUndo` answers the not-followed text only for a flagged entry whose undo was not
    /// found, after putting it back, as every not-found is.
    func testTheHandlerSubstitutesOnlyForAFlaggedNotFound() throws {
        let body = try body("private func handleUndo(arguments: [String: Value]) async throws -> String", in: "Server.swift")
        try assertOrder(["} catch let missing as UndoTargetMissingError where record.seriesNotFollowed {",
                         "await undoManager.restoreFailedUndo(record)",
                         "guard let title = record.operation.notFollowedTitle else { throw missing }",
                         "throw UndoTargetMissingError.seriesNotFollowed(title: title)",
                         "} catch {"], in: body)
    }

    /// The production manager moves records in the shared history the server uses.
    func testTheProductionManagerUsesTheSharedHistory() throws {
        let source = try SourcePins.source(Self.manager)
        assertOnce("static let shared = EventKitManager()", in: source)
        assertOnce("undoHistory: CalendarUndoManager = .shared) {", in: source)
    }

    /// One event rewrite, one flag and one reminder rewrite on the delete-undo path, and no other
    /// caller of the two new ones.
    func testTheCallCounts() throws {
        XCTAssertEqual(try calls("undoHistory.replaceEventIdentifier("), ["EventKitManager+SeriesExceptions.swift": 1])
        XCTAssertEqual(try calls(".markSeriesNotFollowed("), ["EventKitManager+SeriesExceptions.swift": 1])
        XCTAssertEqual(try calls(".replaceReminderIdentifier("), ["EventKitManager.swift": 1])
    }

    /// Every record site of the two cases reads the removed identifier before the removal: the
    /// record type has no default, so a site that leaves it out does not compile; these pins hold
    /// which identifier it reads.
    func testTheRecordSitesReadTheRemovedIdentifierBeforeTheRemoval() throws {
        let snapshots = try body("init(series: EKEvent, removed: EKEvent, span: EKSpan = .thisEvent,", in: "EventKit/DeleteUndo.swift")
        assertOnce("removedID = DeleteUndoFollow.removedIdentifier(eventIdentifier: series.eventIdentifier, hasRules: series.hasRecurrenceRules)", in: snapshots)
        let record = try body("func record(for kind: EventRemovalKind) -> UndoOperation", in: "EventKit/DeleteUndo.swift")
        assertOnce("case .wholeEvent: return .deleteEvent(id: removedID, snapshot: series)", in: record)

        let read = "let removedID = DeleteUndoFollow.removedIdentifier(eventIdentifier: event.eventIdentifier, hasRules: event.hasRecurrenceRules)"
        let series = try body("func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute", in: Self.manager)
        try assertOrder([read, "try eventStore.remove(event, span: .futureEvents)",
                         "await CalendarUndoManager.shared.record(.deleteEvent(id: removedID, snapshot: snapshot))"], in: series)
        let batch = try body("func deleteEventSeriesBatch(identifiers: [String])", in: Self.manager)
        try assertOrder([read, "try eventStore.remove(event, span: .futureEvents)",
                         "undoOperations.append(.deleteEvent(id: removedID, snapshot: snapshot))"], in: batch)

        let reminder = try body("func deleteReminder(identifier: String) async throws", in: Self.manager)
        try assertOrder(["let removedID = reminder.calendarItemIdentifier",
                         "let snapshot = try removeExistingReminder(reminder, handler:",
                         "await CalendarUndoManager.shared.record(.deleteReminder(id: removedID, snapshot: snapshot))"], in: reminder)
        let reminders = try body("func deleteRemindersBatch(identifiers: [String]", in: Self.manager)
        try assertOrder(["guard let snapshot = try commitReminderRemoval(reminder, onlyCompleted: onlyCompleted) else {",
                         "undoSnapshots.append((id: reminder.calendarItemIdentifier, snapshot: snapshot))"], in: reminders)
    }
}
