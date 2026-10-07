import Foundation
import XCTest

/// #248, #243 (PR #282 verify round 1, findings 8, 10, 11, 12): the production wiring of the batch
/// fixes reads the store, so no unit test reaches it; these pins read the source instead and fail
/// when a piece of the wiring is reverted. They read through `SourcePins` (#278): one function from
/// its declaration to its closing brace, comments and string literals blanked.
final class UndoBatchWiringTests: XCTestCase {
    private struct Missing: Error, CustomStringConvertible { let description: String }

    private static let manager = "EventKit/EventKitManager.swift"
    private static let guardFile = "EventKit/EventKitManager+UndoGuard.swift"

    private static func body(_ declaration: String, in file: String) throws -> String {
        guard let body = SourcePins.body(of: declaration, in: try SourcePins.source(file)) else {
            throw Missing(description: "not found: \(declaration) in \(file)")
        }
        return body
    }

    /// The text of `body` from `start` on; the batch arm is the last case of `executeUndo` /
    /// `executeRedo`, so this is that arm.
    private static func from(_ start: String, in body: String) throws -> Substring {
        guard let range = body.range(of: start) else { throw Missing(description: "not found: \(start)") }
        return body[range.lowerBound...]
    }

    /// The offset of the first match of `pattern` in `text`, or nil (and a failure) when it is absent.
    private static func offset(of pattern: String, in text: Substring, file: StaticString = #filePath,
                               line: UInt = #line) -> Int? {
        let string = String(text)
        guard let range = SourcePins.ranges(ofPattern: pattern, in: string).first else {
            XCTFail("missing: \(pattern)", file: file, line: line)
            return nil
        }
        return string.distance(from: string.startIndex, to: range.lowerBound)
    }

    private static func count(_ literal: String, in text: Substring) -> Int {
        SourcePins.ranges(of: literal, in: String(text)).count
    }

    private static func escaped(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
    }

    // MARK: - #248 A: Interrupted is handled in one place (finding 10)

    /// Every batch runs through `UndoBatchExecution.run`, the only caller of `UndoBatchRunner.run`:
    /// a caller that did not unwrap `Interrupted` would put a half-restored record back whole.
    func testOnlyTheBatchHelperCallsTheBatchRunner() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var callers: [String] = []
        for file in files {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            let calls = SourcePins.ranges(of: "UndoBatchRunner.run(", in: code).count
            callers += Array(repeating: file.lastPathComponent, count: calls)
        }
        XCTAssertEqual(callers, ["UndoBatchRestore.swift"],
                       "run a batch through UndoBatchExecution.run, which handles UndoBatchRunner.Interrupted")
    }

    func testBothBatchArmsGoThroughTheHelper() throws {
        let undo = try Self.from("case .batch(let ops):", in: try Self.body("func executeUndo(_ operation: UndoOperation)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: #"UndoBatchExecution\.run\(\s*ops,\s*verb:\s*\.undo,"#, in: undo))
        let redo = try Self.from("case .batch(let ops):", in: try Self.body("func executeRedo(_ operation: UndoOperation)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: #"UndoBatchExecution\.run\(\s*ops,\s*verb:\s*\.redo,"#, in: redo))
    }

    // MARK: - #248 B: the destination pre-check (findings 8 (3), 12, 5)

    /// The undo batch arm refuses a member that can never be restored (#244 D3, which discards the
    /// record) before it checks the destinations (#248 B, which keeps it), so a batch that holds both
    /// is discarded rather than kept for a retry that would refuse again (PR #278 round 2, finding
    /// 24); and both come before the runner writes anything.
    func testTheUndoBatchArmRefusesBeforeAnyWriteThePermanentRefusalFirst() throws {
        let batch = try Self.from("case .batch(let ops):", in: try Self.body("func executeUndo(_ operation: UndoOperation)", in: Self.manager))
        let permanent = try XCTUnwrap(Self.offset(of: #"try\s+verifyBatchMemberRestorable\(\s*\.batch\(ops\),\s*verb:\s*\.undo\s*\)"#, in: batch))
        let destinations = try XCTUnwrap(Self.offset(of: #"try\s+await\s+verifyRestoreDestinations\(of:\s*ops,\s*verb:\s*\.undo\)"#, in: batch))
        let run = try XCTUnwrap(Self.offset(of: #"UndoBatchExecution\.run\("#, in: batch))
        XCTAssertLessThan(permanent, destinations, "the refusal that discards comes first")
        XCTAssertLessThan(destinations, run)
    }

    /// The calendars and lists are read once, before the per-destination lookups, and handed to
    /// `UndoRestoreDestination.firstMissing` with the identifier the restore matches on. No lookup
    /// of its own: a title match let a same-titled list in another account pass (finding 1). The
    /// reminder lists come from `reminderListsForRestore`, the entry the restore reads them through
    /// (#242, PR #277 round 3), so the pre-check has no access check, refresh or list read of its own
    /// for them.
    func testThePreCheckReadsEachListOnceAndHandsThemToTheSharedLookup() throws {
        let body = Substring(try Self.body("func verifyRestoreDestinations(of members: [UndoOperation]", in: Self.guardFile))
        XCTAssertEqual(Self.count("eventStore.calendars(for: .event)", in: body), 1)
        XCTAssertEqual(Self.count("reminderListsForRestore()", in: body), 1)
        XCTAssertEqual(Self.count("calendars(for: .reminder)", in: body), 0)
        XCTAssertEqual(Self.count("ensureReminderAccess", in: body), 0)
        let firstMissing = try XCTUnwrap(Self.offset(of: Self.escaped("UndoRestoreDestination.firstMissing("), in: body))
        XCTAssertLessThan(try XCTUnwrap(Self.offset(of: Self.escaped("eventStore.calendars(for: .event)"), in: body)), firstMissing)
        XCTAssertLessThan(try XCTUnwrap(Self.offset(of: #"try\s+await\s+reminderListsForRestore\(\)"#, in: body)), firstMissing)
        XCTAssertNotNil(Self.offset(of: #"among:\s*destinations,\s*eventCalendars:\s*eventCalendars,\s*reminderLists:\s*reminderLists,\s*identifier:\s*\{\s*\$0\.calendarIdentifier\s*\}"#, in: body))
        XCTAssertEqual(Self.count(".title", in: body), 0, "the pre-check matches no list by title")
        XCTAssertEqual(Self.count("resolve", in: body), 0, "the lookups live in firstMissing")
    }

    /// `firstMissing` makes the restore's own lookups: `EventSnapshot.resolveCalendar`, which
    /// `applySnapshot` calls, and `ReminderSnapshot.resolveList` with `.recreateDeleted`, the kind
    /// the `.deleteReminder` undo restores with (the only reminder record with a destination).
    func testThePreCheckLookupsAreTheOnesTheRestoreMakes() throws {
        let lookup = Substring(try Self.body("static func firstMissing<", in: "EventKit/UndoBatchRestore.swift"))
        XCTAssertNotNil(Self.offset(of: Self.escaped("snapshot.resolveCalendar(in: eventCalendars, identifier: identifier)"), in: lookup))
        XCTAssertNotNil(Self.offset(of: Self.escaped("snapshot.resolveList(in: reminderLists, identifier: identifier, for: .recreateDeleted)"), in: lookup))
        XCTAssertEqual(Self.count(".title", in: lookup), 0)

        // The restore side of each lookup. The reminder write path itself is pinned by
        // `ReminderUndoWiringTests` (#242); here only the kind the delete-undo passes.
        let apply = Substring(try Self.body("private func applySnapshot(_ snapshot: EventSnapshot", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: #"snapshot\.resolveCalendar\(in:\s*eventStore\.calendars\(for:\s*\.event\),\s*identifier:\s*\{\s*\$0\.calendarIdentifier\s*\}\)"#, in: apply))
        let undo = try Self.body("func executeUndo(_ operation: UndoOperation)", in: Self.manager)
        let deleteArm = try Self.from("case .deleteReminder(let snapshot):", in: undo)
        let nextArm = try XCTUnwrap(deleteArm.range(of: "case .updateReminder(").map { deleteArm[..<$0.lowerBound] })
        XCTAssertNotNil(Self.offset(of: Self.escaped("for: .recreateDeleted"), in: nextArm))
    }

    // MARK: - #243: the reminder batch delete record (findings 8 (1), 11)

    /// The snapshot is taken after the only-completed check, kept only after `remove` succeeded,
    /// and recorded once after the loop.
    func testTheReminderBatchDeleteRecordsOnlyTheRemindersItRemoved() throws {
        let body = Substring(try Self.body("func deleteRemindersBatch(identifiers: [String], onlyCompleted: Bool = false)", in: Self.manager))
        let gate = try XCTUnwrap(Self.offset(of: Self.escaped("BatchDeleteFilter.shouldSkipUncompleted("), in: body))
        let snapshot = try XCTUnwrap(Self.offset(of: Self.escaped("let snapshot = ReminderSnapshot(from: reminder)"), in: body))
        let remove = try XCTUnwrap(Self.offset(of: Self.escaped("try eventStore.remove(reminder, commit: true)"), in: body))
        let keep = try XCTUnwrap(Self.offset(of: Self.escaped("undoSnapshots.append(snapshot)"), in: body))
        let loopEnd = try XCTUnwrap(Self.offset(of: Self.escaped("failures.append((id, sanitized.code))"), in: body))
        let record = try XCTUnwrap(Self.offset(of: #"if\s+let\s+undo\s*=\s*UndoOperation\.reminderBatchDelete\(undoSnapshots\)\s*\{\s*await\s+CalendarUndoManager\.shared\.record\(undo\)"#, in: body))
        XCTAssertLessThan(gate, snapshot, "snapshot after the only-completed check")
        XCTAssertLessThan(remove, keep, "kept only after remove succeeded")
        XCTAssertLessThan(loopEnd, record, "recorded once, after the loop")
        XCTAssertEqual(Self.count("undoSnapshots.append(", in: body), 1)
    }
}
