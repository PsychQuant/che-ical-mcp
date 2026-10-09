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
        SourcePins.ranges(ofPattern: call(literal), in: String(text)).count
    }

    /// `literal` as a pattern that tolerates any whitespace around its punctuation and in place of
    /// its spaces (PR #282 round 2, finding 4): a reformatted call still matches; a renamed call,
    /// label or argument does not.
    private static func call(_ literal: String) -> String {
        var pattern = ""
        for character in literal {
            if character == " " { pattern += #"\s*"#; continue }
            let escaped = NSRegularExpression.escapedPattern(for: String(character))
            pattern += "(),:{}[]".contains(character) ? #"\s*"# + escaped + #"\s*"# : escaped
        }
        return pattern
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

    /// The undo of a batch is `undoBatch(_:)` (round 6, findings 2, 9: a nested batch member needs
    /// its differences as data too); the `executeUndo` arm only returns its message.
    private static func undoBatchBody() throws -> Substring {
        Substring(try body("func undoBatch(_ ops: [UndoOperation]) async throws", in: manager))
    }

    func testBothBatchArmsGoThroughTheHelper() throws {
        let arm = try Self.from("case .batch(let ops):", in: try Self.body("func executeUndo(_ operation: UndoOperation)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("return try await undoBatch(ops).message"), in: arm))
        let undo = try Self.undoBatchBody()
        XCTAssertNotNil(Self.offset(of: Self.call("UndoBatchExecution.run(ops, verb: .undo,"), in: undo))
        let redo = try Self.from("case .batch(let ops):", in: try Self.body("func executeRedo(_ operation: UndoOperation)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("UndoBatchExecution.run(ops, verb: .redo,"), in: redo))
    }

    // MARK: - #248 A: what a batch record holds (PR #282 round 4, finding 2)

    /// A batch undo moves a failed member to run last because every batch record holds deletes whose
    /// restores do not depend on each other (`mayRunLastAfterAFailure`). These pins keep the batch
    /// records to the three builders that make them: `deleteEventSeriesBatch` (whole-event deletes),
    /// `deleteEventsBatch` (`DeletedEventSnapshots.record(for:)` only) and the reminder batch delete
    /// (`UndoOperation.reminderBatchDelete`). A new place that builds a `.batch` fails the count.
    func testBatchRecordsAreBuiltOnlyFromDeletes() throws {
        let series = Substring(try Self.body("func deleteEventSeriesBatch(identifiers: [String])", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("CalendarUndoManager.shared.record(.batch(undoSnapshots.map { .deleteEvent(snapshot: $0) }))"), in: series))
        XCTAssertEqual(Self.count(".batch(", in: series), 1)

        // Round 5, findings 5, 16: an `insert`, `+=` or reassignment passed the append count, so
        // every use of the builder's array is counted: its declaration, the one append, the
        // emptiness check and the record.
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bundoSnapshots\b"#, in: String(series)).count, 4)
        XCTAssertNotNil(Self.offset(of: Self.call("var undoSnapshots: [EventSnapshot] = []"), in: series))

        let events = Substring(try Self.body("func deleteEventsBatch(", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("CalendarUndoManager.shared.record(.batch(undoOperations))"), in: events))
        XCTAssertEqual(Self.count("undoOperations.append(", in: events), 1)
        XCTAssertNotNil(Self.offset(of: Self.call("undoOperations.append(snapshots.record(for: kind))"), in: events))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bundoOperations\b"#, in: String(events)).count, 4)
        XCTAssertNotNil(Self.offset(of: Self.call("var undoOperations: [UndoOperation] = []"), in: events))
        XCTAssertNotNil(Self.offset(of: Self.call("if !undoOperations.isEmpty {"), in: events))

        let reminders = Substring(try Self.body("func deleteRemindersBatch(identifiers: [String]", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("UndoOperation.reminderBatchDelete(undoSnapshots)"), in: reminders))
        XCTAssertEqual(Self.count(".batch(", in: reminders), 0)
        // Round 6, finding 28: every use of the reminder builder's array too: its declaration, the
        // one append (after the remove succeeded) and the record.
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bundoSnapshots\b"#, in: String(reminders)).count, 3)
        XCTAssertNotNil(Self.offset(of: Self.call("var undoSnapshots: [ReminderSnapshot] = []"), in: reminders))
        XCTAssertEqual(Self.count("undoSnapshots.append(snapshot)", in: reminders), 1)

        // Every `.batch(...)` built in Sources (a `case .batch(` match is not one): the two event
        // builders, the reminder builder, and three that rebuild an existing record's members (the
        // #244 refusal check of a batch, a narrowed batch, and a nested batch's remainder).
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var built: [String: Int] = [:]
        for file in files {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            let count = SourcePins.ranges(ofPattern: #"(?<!case )\.batch\s*\("#, in: code).count
            if count > 0 { built[file.lastPathComponent, default: 0] += count }
        }
        XCTAssertEqual(built, ["EventKitManager.swift": 3, "UndoManager.swift": 1, "Server.swift": 1, "UndoBatchRestore.swift": 1],
                       "a new .batch record must hold only members that may run last (mayRunLastAfterAFailure)")
    }

    /// Round 6, findings 7, 17 (#283): the snapshot fixtures share one in-memory store instead of
    /// building one per call; too many stores in one process make EventKit refuse the real one.
    func testTheSnapshotFixturesShareOneStore() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Helpers/UndoSnapshotFixtures.swift")
        let code = SourcePins.code(try String(contentsOf: fixtures, encoding: .utf8))
        XCTAssertEqual(SourcePins.ranges(of: "EKEventStore()", in: code).count, 1, code)
        XCTAssertNotNil(Self.offset(of: Self.call("private static let store = EKEventStore()"), in: Substring(code)))
    }

    /// Round 5, finding 8 (#37): the batch refusal puts no calendar or list title and no account on
    /// the trusted path; `UndoBatchRestore.swift` reads neither field.
    func testTheBatchRefusalReadsNoCalendarTitleOrAccount() throws {
        let code = SourcePins.code(try SourcePins.source("EventKit/UndoBatchRestore.swift"))
        XCTAssertEqual(SourcePins.ranges(of: "calendarTitle", in: code).count, 0)
        XCTAssertEqual(SourcePins.ranges(of: "calendarSource", in: code).count, 0)
    }

    /// Round 5, findings 4, 12: the redo batch arm's text comes from the helper that says
    /// "1 operation" for one member.
    func testTheRedoBatchArmUsesTheBatchTextHelper() throws {
        let redo = try Self.from("case .batch(let ops):", in: try Self.body("func executeRedo(_ operation: UndoOperation)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("return UndoOperation.batchRedoneMessage(count: results.count)"), in: redo))
    }

    // MARK: - #248 B: the destination pre-check (findings 8 (3), 12, 5)

    /// The undo batch arm refuses a member that can never be restored (#244 D3, which discards the
    /// record) before it checks the destinations (#248 B, which keeps it), so a batch that holds both
    /// is discarded rather than kept for a retry that would refuse again (PR #278 round 2, finding
    /// 24); and both come before the runner writes anything.
    func testTheUndoBatchArmRefusesBeforeAnyWriteThePermanentRefusalFirst() throws {
        let batch = try Self.undoBatchBody()
        let permanent = try XCTUnwrap(Self.offset(of: Self.call("try verifyBatchMemberRestorable(.batch(ops), verb: .undo)"), in: batch))
        let destinations = try XCTUnwrap(Self.offset(of: Self.call("try await verifyRestoreDestinations(of: ops, verb: .undo)"), in: batch))
        let run = try XCTUnwrap(Self.offset(of: Self.call("UndoBatchExecution.run("), in: batch))
        XCTAssertLessThan(permanent, destinations, "the refusal that discards comes first")
        XCTAssertLessThan(destinations, run)
    }

    /// The calendars and lists are read inside `UndoRestoreDestination.verify`'s `read`, which runs
    /// once, and once more after a missing or read-only destination with the view invalidated first
    /// (round 2, finding 2; round 3, finding 1). The
    /// reminder lists come from `reminderListsForRestore`, the entry the restore reads them through
    /// (#242, PR #277 round 3); the event calendars after the calendar access check (round 2,
    /// finding 10). The containers are matched by the identifier the restore matches on and must
    /// allow changes (finding 5); no lookup of the pre-check's own (round 1, finding 1).
    func testThePreCheckReadsThroughTheSharedEntriesAndRereadsAfterAMiss() throws {
        let body = Substring(try Self.body("func verifyRestoreDestinations(of members: [UndoOperation]", in: Self.guardFile))
        let verify = try XCTUnwrap(Self.offset(of: Self.call("try await UndoRestoreDestination.verify("), in: body))
        XCTAssertNotNil(Self.offset(of: Self.call("identifier: { $0.calendarIdentifier }, allowsModifications: { $0.allowsContentModifications },"), in: body))
        let read = try XCTUnwrap(Self.offset(of: Self.call("read: {"), in: body))
        let access = try XCTUnwrap(Self.offset(of: Self.call("try await self.ensureCalendarAccess()"), in: body))
        let calendars = try XCTUnwrap(Self.offset(of: Self.call("eventCalendars = self.eventStore.calendars(for: .event)"), in: body))
        let lists = try XCTUnwrap(Self.offset(of: Self.call("reminderLists = try await self.reminderListsForRestore()"), in: body))
        let invalidate = try XCTUnwrap(Self.offset(of: Self.call("invalidate: { self.markNeedsRefresh() }"), in: body))
        XCTAssertLessThan(verify, read)
        XCTAssertLessThan(read, access)
        XCTAssertLessThan(access, calendars, "the calendar access check comes before the read")
        XCTAssertLessThan(calendars, invalidate)
        XCTAssertLessThan(lists, invalidate)
        XCTAssertEqual(Self.count("calendars(for: .event)", in: body), 1)
        XCTAssertEqual(Self.count("reminderListsForRestore()", in: body), 1)
        XCTAssertEqual(Self.count("calendars(for: .reminder)", in: body), 0)
        XCTAssertEqual(Self.count("ensureReminderAccess", in: body), 0)
        XCTAssertEqual(Self.count(".title", in: body), 0, "the pre-check matches no list by title")
        XCTAssertEqual(Self.count("resolve", in: body), 0, "the lookups live in UndoRestoreDestination.problems")
    }

    /// `verify` re-reads only after a finding, with the view invalidated first, and `problems` makes the
    /// restore's own lookups: `EventSnapshot.resolveCalendar`, which `applySnapshot` calls, and
    /// `ReminderSnapshot.resolveList` with `.recreateDeleted`, the kind the `.deleteReminder` undo
    /// restores with (the only reminder record with a destination).
    func testThePreCheckLookupsAreTheOnesTheRestoreMakes() throws {
        let file = "EventKit/UndoBatchRestore.swift"
        let lookup = Substring(try Self.body("static func problems<", in: file))
        XCTAssertNotNil(Self.offset(of: Self.call("snapshot.resolveCalendar(in: eventCalendars, identifier: identifier)"), in: lookup))
        XCTAssertNotNil(Self.offset(of: Self.call("snapshot.resolveList(in: reminderLists, identifier: identifier, for: .recreateDeleted)"), in: lookup))
        XCTAssertNotNil(Self.offset(of: Self.call("allowsModifications(container)"), in: lookup))
        XCTAssertEqual(Self.count(".title", in: lookup), 0)

        // The restore side of each lookup. The reminder write path itself is pinned by
        // `ReminderUndoWiringTests` (#242); here only the kind the delete-undo passes.
        let apply = Substring(try Self.body("private func applySnapshot(_ snapshot: EventSnapshot", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier })"), in: apply))
        // Since #280 the delete-undo, single and batch member, restores through
        // `restoreDeletedReminder`; that is where the kind is passed.
        let restore = Substring(try Self.body("func restoreDeletedReminder(_ snapshot: ReminderSnapshot)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("for: .recreateDeleted"), in: restore))
    }

    /// PR #282 round 5, finding 1, with #280 round 7: the undo batch arm runs every member through
    /// `undoBatchMember`, which restores a deleted reminder through `restoreDeletedReminder` and
    /// passes the names it returns as data (`UndoRestoredDifference`); every other member runs
    /// `executeUndo`. The batch text is built from those names (`batchUndoneMessage(…, differing:)`,
    /// which calls `UndoRestoredDifference.sentences`, worded by `NewObjectSave.differingFieldsNote`),
    /// and no member text is read back: the arm uses only
    /// the count of the member texts.
    func testTheUndoBatchArmCarriesRestoredRemindersDifferencesAsData() throws {
        let batch = try Self.undoBatchBody()
        XCTAssertNotNil(Self.offset(of: Self.call("restore: { try await self.undoBatchMember($0) },"), in: batch))
        XCTAssertNotNil(Self.offset(of: Self.call("return (UndoOperation.batchUndoneMessage(members: ops, count: outcome.texts.count, differing: outcome.differing), outcome.differing)"), in: batch))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\boutcome\.texts\b"#, in: String(batch)).count, 1, "only the count of the member texts is used")
        XCTAssertEqual(Self.count("restoreDeletedReminder(", in: batch), 0, "reminders go through undoBatchMember")

        let member = Substring(try Self.body("func undoBatchMember(_ operation: UndoOperation)", in: Self.manager))
        XCTAssertNotNil(Self.offset(of: Self.call("guard case .deleteReminder(let snapshot) = operation else {"), in: member))
        XCTAssertNotNil(Self.offset(of: Self.call("return UndoMemberOutcome(text: try await executeUndo(operation), differing: [])"), in: member))
        // Round 6, findings 2, 9: a nested batch member carries its own members' differences up.
        XCTAssertNotNil(Self.offset(of: Self.call("if case .batch(let inner) = operation {"), in: member))
        XCTAssertNotNil(Self.offset(of: Self.call("let undone = try await undoBatch(inner)"), in: member))
        XCTAssertNotNil(Self.offset(of: Self.call("return UndoMemberOutcome(text: undone.message, differing: undone.differing)"), in: member))
        XCTAssertNotNil(Self.offset(of: Self.call("let restored = try await restoreDeletedReminder(snapshot)"), in: member))
        XCTAssertNotNil(Self.offset(of: Self.call("differing: [UndoRestoredDifference(title: restored.title, storeDiffers: restored.storeDiffers)])"), in: member))

        let text = Substring(try XCTUnwrap(SourcePins.body(of: "static func batchUndoneMessage(", in: try SourcePins.source("EventKit/DeleteUndo.swift"))))
        XCTAssertNotNil(Self.offset(of: Self.call("let named = UndoRestoredDifference.sentences(differing)"), in: text))
        let restoreFile = try SourcePins.source("EventKit/UndoBatchRestore.swift")
        XCTAssertEqual(SourcePins.ranges(of: "UndoRestoredDifference.sentences(restoredDiffering)", in: SourcePins.code(restoreFile)).count, 1,
                       "a batch stopped part-way names the restored reminders' differences")
        let sentences = Substring(try XCTUnwrap(SourcePins.body(of: "static func sentences(_ differences: [UndoRestoredDifference])", in: restoreFile)))
        XCTAssertNotNil(Self.offset(of: Self.call("NewObjectSave.differingFieldsNote(difference.storeDiffers)"), in: sentences),
                        "the words are #280's one formatter's")
    }

    /// Round 2, finding 20: the runner's `check` is #236's per-member pre-flight; an empty closure
    /// would leave the batch arm without it.
    func testTheBatchArmsCheckEachMemberWithThePerMemberPreFlight() throws {
        let redo = try Self.from("case .batch(let ops):", in: try Self.body("func executeRedo(_ operation: UndoOperation)", in: Self.manager))
        for (batch, verb) in [(try Self.undoBatchBody(), "undo"), (redo, "redo")] {
            XCTAssertNotNil(Self.offset(of: Self.call("check: { try await self.verifyHistoryTarget(of: $0, verb: .\(verb)) },"), in: batch), verb)
        }
    }

    // MARK: - #243: the reminder batch delete record (findings 8 (1), 11)

    /// The snapshot is taken after the only-completed check, kept only after `remove` succeeded,
    /// and recorded once after the loop.
    func testTheReminderBatchDeleteRecordsOnlyTheRemindersItRemoved() throws {
        let body = Substring(try Self.body("func deleteRemindersBatch(identifiers: [String], onlyCompleted: Bool = false)", in: Self.manager))
        let gate = try XCTUnwrap(Self.offset(of: Self.call("BatchDeleteFilter.shouldSkipUncompleted("), in: body))
        let snapshot = try XCTUnwrap(Self.offset(of: Self.call("let snapshot = ReminderSnapshot(from: reminder)"), in: body))
        let remove = try XCTUnwrap(Self.offset(of: Self.call("try eventStore.remove(reminder, commit: true)"), in: body))
        let keep = try XCTUnwrap(Self.offset(of: Self.call("undoSnapshots.append(snapshot)"), in: body))
        let loopEnd = try XCTUnwrap(Self.offset(of: Self.call("failures.append((id, sanitized.code))"), in: body))
        let record = try XCTUnwrap(Self.offset(of: Self.call("if let undo = UndoOperation.reminderBatchDelete(undoSnapshots) { await CalendarUndoManager.shared.record(undo)"), in: body))
        XCTAssertLessThan(gate, snapshot, "snapshot after the only-completed check")
        XCTAssertLessThan(remove, keep, "kept only after remove succeeded")
        XCTAssertLessThan(loopEnd, record, "recorded once, after the loop")
        XCTAssertEqual(Self.count("undoSnapshots.append(", in: body), 1)
    }
}
