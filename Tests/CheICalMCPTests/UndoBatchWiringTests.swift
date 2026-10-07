import Foundation
import XCTest

/// #248, #243 (PR #282 verify round 1, findings 8, 10, 11, 12): the production wiring of the batch
/// fixes reads the store, so no unit test reaches it; these pins read the source instead and fail
/// when a piece of the wiring is reverted. Comments are stripped before matching.
final class UndoBatchWiringTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private struct Missing: Error, CustomStringConvertible { let description: String }

    /// The file's code with `//` comments removed, so a comment that names a call does not count.
    private static func code(_ relativePath: String) throws -> String {
        try strip(String(contentsOf: sources.appendingPathComponent(relativePath), encoding: .utf8))
    }

    private static func strip(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n")
    }

    /// The text from `start` up to the next member declaration at the indentation of an actor or
    /// extension member, or the end of the type.
    private static func section(from start: String, in text: String) throws -> Substring {
        guard let range = text.range(of: start) else { throw Missing(description: "not found: \(start)") }
        let rest = text[range.lowerBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    fileprivate func ", "\n    static func ", "\n    var ", "\n}\n"]
            .compactMap { rest.dropFirst(start.count).range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    private static func offset(of needle: String, in text: Substring, file: StaticString = #filePath,
                                line: UInt = #line) -> Int? {
        guard let range = text.range(of: needle) else {
            XCTFail("missing: \(needle)", file: file, line: line)
            return nil
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private static func occurrences(of needle: String, in text: Substring) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static let manager = "CheICalMCP/EventKit/EventKitManager.swift"
    private static let guardFile = "CheICalMCP/EventKit/EventKitManager+UndoGuard.swift"

    // MARK: - #248 A: Interrupted is handled in one place (finding 10)

    /// Every batch runs through `UndoBatchExecution.run`, the only caller of `UndoBatchRunner.run`:
    /// a caller that did not unwrap `Interrupted` would put a half-restored record back whole.
    func testOnlyTheBatchHelperCallsTheBatchRunner() throws {
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var callers: [String] = []
        for file in files {
            let text = Self.strip(try String(contentsOf: file, encoding: .utf8))
            let count = Self.occurrences(of: "UndoBatchRunner.run(", in: text[...])
            callers += Array(repeating: file.lastPathComponent, count: count)
        }
        XCTAssertEqual(callers, ["UndoBatchRestore.swift"],
                       "run a batch through UndoBatchExecution.run, which handles UndoBatchRunner.Interrupted")
    }

    func testBothBatchArmsGoThroughTheHelper() throws {
        let manager = try Self.code(Self.manager)
        let undo = try Self.section(from: "func executeUndo(_ operation: UndoOperation)", in: manager)
        let undoBatch = try XCTUnwrap(undo.range(of: "case .batch(let ops):").map { undo[$0.lowerBound...] })
        XCTAssertNotNil(Self.offset(of: "UndoBatchExecution.run(\n                ops, verb: .undo,", in: undoBatch))
        let redo = try Self.section(from: "func executeRedo(_ operation: UndoOperation)", in: manager)
        let redoBatch = try XCTUnwrap(redo.range(of: "case .batch(let ops):").map { redo[$0.lowerBound...] })
        XCTAssertNotNil(Self.offset(of: "UndoBatchExecution.run(\n                ops, verb: .redo,", in: redoBatch))
    }

    // MARK: - #248 B: the destination pre-check (findings 8 (3), 12, 5)

    /// The undo batch arm checks the destinations before the runner writes anything.
    func testTheUndoBatchArmChecksTheDestinationsBeforeAnyWrite() throws {
        let manager = try Self.code(Self.manager)
        let undo = try Self.section(from: "func executeUndo(_ operation: UndoOperation)", in: manager)
        let batch = try XCTUnwrap(undo.range(of: "case .batch(let ops):").map { undo[$0.lowerBound...] })
        let check = try XCTUnwrap(Self.offset(of: "try await verifyRestoreDestinations(of: ops, verb: .undo)", in: batch))
        let run = try XCTUnwrap(Self.offset(of: "UndoBatchExecution.run(", in: batch))
        XCTAssertLessThan(check, run)
    }

    /// The calendars and lists are read once, before the per-destination lookups, and handed to
    /// `UndoRestoreDestination.firstMissing` with the identifier the restore matches on. No lookup
    /// of its own: a title match let a same-titled list in another account pass (finding 1).
    func testThePreCheckReadsEachListOnceAndHandsThemToTheSharedLookup() throws {
        let guardCode = try Self.code(Self.guardFile)
        let body = try Self.section(from: "func verifyRestoreDestinations(of members: [UndoOperation]", in: guardCode)
        XCTAssertEqual(Self.occurrences(of: "eventStore.calendars(for: .event)", in: body), 1)
        XCTAssertEqual(Self.occurrences(of: "eventStore.calendars(for: .reminder)", in: body), 1)
        let firstMissing = try XCTUnwrap(Self.offset(of: "UndoRestoreDestination.firstMissing(", in: body))
        XCTAssertLessThan(try XCTUnwrap(Self.offset(of: "eventStore.calendars(for: .event)", in: body)), firstMissing)
        XCTAssertLessThan(try XCTUnwrap(Self.offset(of: "eventStore.calendars(for: .reminder)", in: body)), firstMissing)
        XCTAssertNotNil(Self.offset(of: "among: destinations, eventCalendars: eventCalendars, reminderLists: reminderLists,\n            identifier: { $0.calendarIdentifier })", in: body))
        XCTAssertEqual(Self.occurrences(of: ".title", in: body), 0, "the pre-check matches no list by title")
        XCTAssertEqual(Self.occurrences(of: "resolve", in: body), 0, "the lookups live in firstMissing")
    }

    /// `firstMissing` makes the restore's own lookups: `EventSnapshot.resolveCalendar`, which
    /// `applySnapshot` calls, and `ReminderSnapshot.resolveList(for: .recreateDeleted)`, which
    /// `applyReminderSnapshot` calls (through `ReminderSnapshot.apply(to:lists:for:now:)`) for the
    /// `.deleteReminder` undo, the only reminder record with a destination.
    func testThePreCheckLookupsAreTheOnesTheRestoreMakes() throws {
        let restore = try Self.code("CheICalMCP/EventKit/UndoBatchRestore.swift")
        let lookup = try Self.section(from: "static func firstMissing<", in: restore)
        XCTAssertNotNil(Self.offset(of: "snapshot.resolveCalendar(in: eventCalendars, identifier: identifier)", in: lookup))
        XCTAssertNotNil(Self.offset(of: "snapshot.resolveList(in: reminderLists, identifier: identifier, for: .recreateDeleted)", in: lookup))
        XCTAssertEqual(Self.occurrences(of: ".title", in: lookup), 0)

        let manager = try Self.code(Self.manager)
        let apply = try Self.section(from: "private func applySnapshot(_ snapshot: EventSnapshot", in: manager)
        XCTAssertNotNil(Self.offset(of: "snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier })", in: apply))
        let applyReminder = try Self.section(from: "private func applyReminderSnapshot(_ snapshot: ReminderSnapshot", in: manager)
        XCTAssertNotNil(Self.offset(of: "try snapshot.apply(to: reminder, lists: eventStore.calendars(for: .reminder), for: kind, now: Date())", in: applyReminder))
        let undo = try Self.section(from: "func executeUndo(_ operation: UndoOperation)", in: manager)
        let deleteArm = try XCTUnwrap(undo.range(of: "case .deleteReminder(let snapshot):").map { undo[$0.lowerBound...] })
        XCTAssertNotNil(Self.offset(of: "try applyReminderSnapshot(snapshot, to: reminder, for: .recreateDeleted)", in: deleteArm))
        let snapshotApply = try Self.section(from: "func apply(to reminder: EKReminder, lists: [EKCalendar], for kind: ReminderRestoreKind",
                                             in: try Self.code("CheICalMCP/EventKit/UndoManager.swift"))
        XCTAssertNotNil(Self.offset(of: "try resolveList(in: lists, identifier: { $0.calendarIdentifier }, for: kind)", in: snapshotApply))
    }

    // MARK: - #243: the reminder batch delete record (findings 8 (1), 11)

    /// The snapshot is taken after the only-completed check, kept only after `remove` succeeded,
    /// and recorded once after the loop.
    func testTheReminderBatchDeleteRecordsOnlyTheRemindersItRemoved() throws {
        let manager = try Self.code(Self.manager)
        let body = try Self.section(from: "func deleteRemindersBatch(identifiers: [String], onlyCompleted: Bool = false)", in: manager)
        let gate = try XCTUnwrap(Self.offset(of: "BatchDeleteFilter.shouldSkipUncompleted(", in: body))
        let snapshot = try XCTUnwrap(Self.offset(of: "let snapshot = ReminderSnapshot(from: reminder)", in: body))
        let remove = try XCTUnwrap(Self.offset(of: "try eventStore.remove(reminder, commit: true)", in: body))
        let keep = try XCTUnwrap(Self.offset(of: "undoSnapshots.append(snapshot)", in: body))
        let loopEnd = try XCTUnwrap(Self.offset(of: "failures.append((id, sanitized.code))", in: body))
        let record = try XCTUnwrap(Self.offset(of: "if let undo = UndoOperation.reminderBatchDelete(undoSnapshots) {\n            await CalendarUndoManager.shared.record(undo)", in: body))
        XCTAssertLessThan(gate, snapshot, "snapshot after the only-completed check")
        XCTAssertLessThan(remove, keep, "kept only after remove succeeded")
        XCTAssertLessThan(loopEnd, record, "recorded once, after the loop")
        XCTAssertEqual(Self.occurrences(of: "undoSnapshots.append(", in: body), 1)
    }
}
