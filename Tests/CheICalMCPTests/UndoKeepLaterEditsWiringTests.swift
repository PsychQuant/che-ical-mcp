import XCTest
@testable import CheICalMCP

/// #265: the production wiring of `keep_later_edits`, which writes to the store and so no unit test
/// runs: the merge arms keep the update arm's order (calendar or lists read first, the guard with the
/// merge hook, the masked restore, the save with rollback), only update records are merged, and the
/// default arms and `apply` are unchanged.
final class UndoKeepLaterEditsWiringTests: XCTestCase {
    private static let file = "EventKit/EventKitManager+KeepLaterEdits.swift"

    private static func body(_ declaration: String, in file: String) throws -> String {
        SourcePins.code(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source(file)), declaration))
    }

    private func assertOrder(_ needles: [String], in body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var last = body.startIndex
        for needle in needles {
            let range = try XCTUnwrap(body.range(of: needle, range: last..<body.endIndex), "\(needle) after the previous step", file: file, line: line)
            last = range.upperBound
        }
    }

    func testOnlyUpdateRecordsAreMerged() throws {
        let dispatch = try Self.body("func executeUndoKeepingLaterEdits(", in: Self.file)
        XCTAssertTrue(dispatch.contains("case .updateEvent(_, let old, let saved):"))
        XCTAssertTrue(dispatch.contains("case .updateReminder(_, let old, let saved):"))
        XCTAssertTrue(dispatch.contains("default: return try await executeUndo(operation)"), "every other record undoes as without the flag")
    }

    func testTheEventMergeKeepsTheUpdateArmsOrder() throws {
        let arm = try Self.body("private func undoUpdatedEventKeepingLaterEdits(", in: Self.file)
        // Round 2 (LOW 3): the calendar is read before the guard (it suspends), and its error counts
        // only when the calendar's group is restored.
        try assertOrder(["let calendarRead: Result<EKCalendar, Error>",
                         "verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits:",
                         "? try calendarRead.get() : event.calendar",
                         "old.applyRestoring(Set(plan.restored), to: event, calendar: calendar)",
                         "try eventStore.save(event, span: .thisEvent)",
                         "event.rollback()",
                         "markNeedsRefresh()"], in: arm)
        // Rounds 1-2: between the merge's check and its write every await is a fallback that returns
        // (the default undo runs its own check), so nothing suspends before the write.
        let check = try XCTUnwrap(arm.range(of: "verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits:"))
        let save = try XCTUnwrap(arm.range(of: "try eventStore.save(event, span: .thisEvent)"))
        let between = String(arm[check.upperBound..<save.lowerBound])
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bawait\b"#, in: between).count,
                       SourcePins.ranges(of: "else { return try await executeUndo(operation) }", in: between).count, between)
        XCTAssertTrue(between.contains("let plan = merge else { return try await executeUndo(operation) }"), between)
    }

    /// Round 1: an update that changed nothing undo restores takes the default undo, and no path of
    /// the merge discards the record.
    func testTheMergeFallsBackToTheDefaultUndoAndNeverDiscards() throws {
        let file = SourcePins.code(try SourcePins.source(Self.file))
        XCTAssertFalse(file.contains("UnrecoverableUndoError"))
        XCTAssertEqual(SourcePins.ranges(of: "guard !changedByUpdate.isEmpty else { return try await executeUndo(operation) }", in: file).count, 2)
        XCTAssertEqual(SourcePins.ranges(of: "UndoKeepLaterEdits.changedByUpdate(old: old, saved: saved)", in: file).count, 2)
    }

    func testTheReminderMergeKeepsTheUpdateArmsOrder() throws {
        let arm = try Self.body("private func undoUpdatedReminderKeepingLaterEdits(", in: Self.file)
        try assertOrder(["let lists = try await reminderListsForRestore()",
                         "verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits:",
                         "? try old.resolveList(in: lists, identifier: { $0.calendarIdentifier }, for: .revertUpdate) : nil",
                         "old.applyRestoring(Set(plan.restored), to: reminder, list: list, now: Date())",
                         "let note = try saveForHistory(reminder, handler:",
                         "markNeedsRefresh()"], in: arm)
    }

    /// The hook runs where the default comparison runs, after the recurring refusal, and replaces
    /// only the list of blocking fields.
    func testTheGuardAppliesTheHookAfterTheRecurringRefusal() throws {
        let guardSource = SourcePins.code(try SourcePins.source("EventKit/EventKitManager+UndoGuard.swift"))
        let target = try XCTUnwrap(SourcePins.body(of: "func verifiedHistoryTarget(", in: guardSource))
        let recurring = try XCTUnwrap(target.range(of: "operation.recurringTargetRefusal("))
        let hook = try XCTUnwrap(target.range(of: "keepingLaterEdits?(event, expected.changedFields(in: event))"))
        XCTAssertLessThan(recurring.lowerBound, hook.lowerBound)
        XCTAssertTrue(target.contains("keepingLaterEdits?(reminder, expected.changedFields(in: reminder))"))
    }

    /// The default update arm and `apply` are untouched: delete-undo still recreates whole events.
    func testTheDefaultUpdateArmStillWritesEveryField() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        XCTAssertTrue(manager.contains("oldSnapshot.apply(to: event, calendar: calendar)"))
        let apply = try Self.body("func apply(to event: EKEvent, calendar: EKCalendar)", in: "EventKit/UndoManager.swift")
        XCTAssertFalse(apply.contains("fields"), "apply writes every recorded field")
    }

    func testTheHandlerRoutesTheFlag() throws {
        let handler = try Self.body("private func handleUndo(arguments:", in: "Server.swift")
        XCTAssertTrue(handler.contains("executeUndoKeepingLaterEdits(record.operation)"))
        XCTAssertTrue(handler.contains("executeUndo(record.operation, restoreAvailable: restoreAvailable)"))
    }
}
