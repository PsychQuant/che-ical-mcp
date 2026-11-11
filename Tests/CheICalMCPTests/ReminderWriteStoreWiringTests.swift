import XCTest
@testable import CheICalMCP

/// #459: where the write store is used. No in-memory store can run these paths, so they are pinned
/// by reading `Sources/` (`*WiringTests`, see CLAUDE.md).
final class ReminderWriteStoreWiringTests: XCTestCase {
    private func body(_ declaration: String, in file: String) throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source(file)), declaration))
    }

    /// Each commit looks the item up on the write store by identifier, reports a nil lookup as a
    /// store error, commits there, and then rolls the caller's object back and refreshes it.
    func testEachCommitRunsOnTheWriteStore() throws {
        let file = "EventKit/ExistingReminderSave.swift"
        let save = try body("func commitReminderSave(_ reminder: EKReminder, requested: Set<ReminderFieldCopy.Field> = [],", in: file)
        XCTAssertTrue(save.contains("try onWriteStore { store in"), save)
        XCTAssertTrue(save.contains("store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), save)
        // Round 3: through the `ExistingReminderSave.commit` seam (lookup, baseline, write, save).
        XCTAssertTrue(save.contains("let (copy, before) = try ExistingReminderSave.commit( lookup: {"), save)
        XCTAssertTrue(save.contains("write: { try ReminderFieldCopy.apply(wanted, fields: fields, to: $0, calendar: { store.calendar(withIdentifier: $0) }, dates: dates) }"), save)
        XCTAssertTrue(save.contains("save: { try store.save($0, commit: true) })"), save)

        let removal = try body("func commitReminderRemoval(_ reminder: EKReminder, onlyCompleted: Bool = false) throws -> ReminderSnapshot? {", in: file)
        XCTAssertTrue(removal.contains("try onWriteStore { store in try ExistingReminderSave.removal("), removal)
        XCTAssertTrue(removal.contains("as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), removal)
        XCTAssertTrue(removal.contains("snapshot: { ReminderSnapshot(from: $0) },"), removal)
        XCTAssertTrue(removal.contains("remove: { try store.remove($0, commit: true) })"), removal)
        XCTAssertTrue(removal.hasSuffix("guard removed != nil else { return nil } reminder.rollback() _ = reminder.refresh() return removed }"), removal)

        let list = try body("func commitListSave(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {", in: file)
        XCTAssertTrue(list.contains("guard let copy = store.calendar(withIdentifier: calendar.calendarIdentifier) else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), list)
        XCTAssertTrue(list.contains("try store.saveCalendar(copy, commit: true)"), list)

        let listRemoval = try body("func commitListRemoval(_ calendar: EKCalendar) throws {", in: file)
        XCTAssertTrue(listRemoval.contains("guard let copy = store.calendar(withIdentifier: calendar.calendarIdentifier) else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), listRemoval)
        XCTAssertTrue(listRemoval.contains("try store.removeCalendar(copy, commit: true)"), listRemoval)
        XCTAssertTrue(listRemoval.hasSuffix("calendar.rollback() _ = calendar.refresh() }"), listRemoval)
    }

    /// A write uses the call's lease when there is one, and otherwise a lease of its own.
    func testAWriteUsesTheCallsLeaseOrItsOwn() throws {
        let file = "EventKit/ExistingReminderSave.swift"
        let run = try body("func onWriteStore<T>(_ body: (EKEventStore) throws -> T) throws -> T {", in: file)
        XCTAssertTrue(run.contains("throws -> T { defer { writeStoreCommits &+= 1 } if let lease = WriteStoreContext.current as? WriteStoreLease<EKEventStore> { return try lease.use(body) }"), run)
        XCTAssertTrue(run.contains("let lease = WriteStoreLease(pool: writeStores) defer { lease.close() } return try lease.use(body)"), run)
        let scope = try body("func withWriteLease<T>(_ operation: () async throws -> T) async rethrows -> T {", in: file)
        XCTAssertTrue(scope.contains("WriteStoreContext.$current.withValue(lease)"), scope)
    }

    /// One write store per batch call: the batch delete, and undo and redo (whose batch records run
    /// every member inside the same call).
    func testBatchCallsAndUndoAndRedoRunInALease() throws {
        let manager = "EventKit/EventKitManager.swift"
        let batch = try body("func deleteRemindersBatch(identifiers: [String], onlyCompleted: Bool = false) async throws -> BatchDeleteResult {", in: manager)
        XCTAssertTrue(batch.contains("-> BatchDeleteResult { try await withWriteLease { try await ensureReminderAccess()"), batch)
        XCTAssertTrue(batch.contains("try commitReminderRemoval(reminder, onlyCompleted: onlyCompleted)"), batch)
        for declaration in ["func executeUndo(_ operation: UndoOperation) async throws -> String {",
                            "func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String {",
                            "func executeRedo(_ operation: UndoOperation) async throws -> String {"] {
            let entry = try body(declaration, in: manager)
            XCTAssertTrue(entry.contains("-> String { guard WriteStoreContext.current is WriteStoreLease<EKEventStore> else { return try await withWriteLease {"), entry)
        }
    }

    /// Creates and event writes stay on the long-lived store: the write store is used only here.
    func testOnlyTheExistingReminderWritesUseTheWriteStore() throws {
        var found: [String] = []
        for file in try SourceScan.swiftFiles() {
            let code = SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8))
            if code.contains("onWriteStore {") || code.contains("onWriteStore{") { found.append(file.lastPathComponent) }
        }
        XCTAssertEqual(found, ["ExistingReminderSave.swift"])
        XCTAssertTrue(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift"))
            .contains("let writeStores = WriteStorePool<EKEventStore>(make: { EKEventStore() }, isUsable: { !$0.sources.isEmpty })"))
    }

    /// PR #507 round 1, LOW 7: in the batch, the write store's own errors are caught before the
    /// sanitizer's catch, keep their own code with a stderr line, and a busy pool ends the call.
    func testTheBatchKeepsTheWriteStoreRowCodes() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        let clause = "} catch let error as EventKitError where WriteStoreRowFailure.code(for: error) != nil { if WriteStoreRowFailure.endsTheBatch(error, removedSoFar: successCount) { throw error }"
        XCTAssertTrue(manager.contains(clause))
        XCTAssertTrue(manager.contains("FileHandle.standardError.write(Data("), "a stderr line")
        XCTAssertTrue(manager.contains("failures.append((id, code)) } catch { "), "the generic catch follows")
    }

    // MARK: - PR #507 round 1: the object the save leaves behind

    /// A failed read-back after a save is an error, not a refresh result left unread: both commits
    /// return what was read back and both wrappers throw `writeStoreReadBackFailed` without it.
    func testAFailedReadBackAfterASaveIsAnError() throws {
        let source = try SourcePins.source("EventKit/ExistingReminderSave.swift")
        // PR #507 round 2: the wrappers answer what was committed when it cannot be read back, and
        // the callers record their undo before they report it (the history pins below).
        let commitSaveBody = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder, requested: Set<ReminderFieldCopy.Field> = [],", in: source)))
        XCTAssertTrue(commitSaveBody.contains("guard let saved = resolvedAfterSave(reminder, savedID: committed.identifier) else { return .unread(committed) }"), commitSaveBody)
        let list = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func saveExistingCalendar(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {", in: source)))
        XCTAssertTrue(list.hasSuffix("return readBack }"), list)
        let commitList = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitListSave(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {", in: source)))
        XCTAssertTrue(commitList.hasSuffix("return calendar.refresh() }"), commitList)
        // A removal's refresh is false by design (the item is gone); a save's is the read-back.
        let commitSave = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder, requested: Set<ReminderFieldCopy.Field> = [],", in: source)))
        XCTAssertFalse(commitSave.contains("_ = reminder.refresh()"), commitSave)
        XCTAssertFalse(commitList.contains("_ = calendar.refresh()"), commitList)
    }

    /// The HIGH: the identifier comes off the write store's copy after its save, and a different one
    /// is resolved again on this server's store.
    func testTheSavedIdentifierComesOffTheCopyAndIsResolvedAgain() throws {
        let source = try SourcePins.source("EventKit/ExistingReminderSave.swift")
        let commit = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder, requested: Set<ReminderFieldCopy.Field> = [],", in: source)))
        XCTAssertTrue(commit.contains("save: { try store.save($0, commit: true) }) return CommittedReminder(identifier: copy.calendarItemIdentifier, snapshot: ReminderSnapshot(from: copy), completion: ReminderCompletionSnapshot(from: copy), before: before.0, completionBefore: before.1) }"), commit)
        XCTAssertTrue(commit.hasSuffix("return .readBack(saved, committed) }"), commit)
        let resolve = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func resolvedAfterSave(_ reminder: EKReminder, savedID: String) -> EKReminder? {", in: source)))
        XCTAssertTrue(resolve.contains("if savedID == reminder.calendarItemIdentifier { return reminder.refresh() ? reminder : nil }"), resolve)
        XCTAssertTrue(resolve.contains("eventStore.calendarItem(withIdentifier: savedID) as? EKReminder, moved.refresh()"), resolve)
    }

    /// The changed fields are taken against the caller's object rolled back, before the write store
    /// is touched, so no field the call left alone reaches the copy.
    func testTheChangeIsTakenAgainstTheRolledBackObject() throws {
        let source = try SourcePins.source("EventKit/ExistingReminderSave.swift")
        let commit = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder, requested: Set<ReminderFieldCopy.Field> = [],", in: source)))
        XCTAssertTrue(commit.contains("let wanted = ReminderFieldCopy.Values(reminder) reminder.rollback() let fields = ReminderFieldCopy.changed(from: ReminderFieldCopy.Values(reminder), to: wanted).union(requested)"), commit)
        XCTAssertTrue(commit.contains("write: { try ReminderFieldCopy.apply(wanted, fields: fields, to: $0,"), commit)
        let list = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitListSave(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {", in: source)))
        XCTAssertTrue(list.contains("let wanted = ListFieldCopy.Values(calendar) calendar.rollback() let fields = ListFieldCopy.changed(from: ListFieldCopy.Values(calendar), to: wanted).union(requested)"), list)
        XCTAssertTrue(list.contains("ListFieldCopy.apply(wanted, fields: fields, to: copy)"), list)
    }

    /// update_reminder reads back, answers and records the reminder the save left behind, so a move
    /// that changed the identifier is answered and recorded under the new one.
    func testUpdateReminderUsesTheReminderTheSaveLeftBehind() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(manager.contains("var saved = reminder var unread: CommittedReminder? let requested = ReminderUpdateWrite.requestedFields(request)"), "update_reminder")
        XCTAssertTrue(manager.contains("reload: { saved.refresh() }, rollback: { saved.rollback() }, current: { saved })"))
        XCTAssertTrue(manager.contains("reminder: ReminderWriteSnapshot(from: saved), dateSync: dateSync"))
        XCTAssertTrue(manager.contains("let savedID = saved.calendarItemIdentifier await CalendarUndoManager.shared.record(.updateReminder(id: savedID, oldSnapshot: baseline ?? cachedBefore, saved: postWriteSnapshot(reminderID: savedID, saved: saved)))"))
        let write = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/ReminderUpdateWrite.swift")))
        XCTAssertTrue(write.contains("return ReminderDateSync.confirmSaved(current?() ?? reminder, report: dateSync,"))
    }

    /// PR #507 round 2 (HIGH): a save that landed but cannot be read back records its undo from the
    /// write store's copy before the error, in update_reminder and in complete_reminder; an undo or
    /// redo whose save landed moves the stacks as a success and says so in its message.
    func testAnUnreadSaveRecordsItsUndoBeforeItIsReported() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(manager.contains("case .unread(let committed): baseline = baseline ?? committed.before unread = committed throw EventKitError.writeStoreReadBackFailed(kind: "))
        XCTAssertTrue(manager.contains("} catch { guard let committed = unread else { throw error } try await recordUnreadUpdate(committed, oldSnapshot: baseline ?? cachedBefore, passed: identifier) }"))
        XCTAssertTrue(manager.contains("if let committed = unread { try await recordUnreadUpdate(committed, oldSnapshot: baseline ?? cachedBefore, passed: identifier) }"))
        let record = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func recordUnreadUpdate(_ committed: CommittedReminder, oldSnapshot: ReminderSnapshot, passed: String) async throws -> Never {", in: try SourcePins.source("EventKit/EventKitManager.swift"))))
        XCTAssertTrue(record.contains("await CalendarUndoManager.shared.record(.updateReminder(id: committed.identifier, oldSnapshot: oldSnapshot, saved: committed.snapshot)) throw EventKitError.writeStoreReadBackFailed(kind: , undo: .recorded, newIdentifier: committed.newIdentifier(passed: passed))"), record)
        let completion = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager+ReminderCompletion.swift")))
        XCTAssertTrue(completion.contains("} catch let unread as UnreadSaveError { markNeedsRefresh() await CalendarUndoManager.shared.record(.forCompletion(before: unread.committed.completionBefore, requestedCompleted: completed, savedTitle: unread.committed.completion.title,"))
        XCTAssertTrue(completion.contains("throw EventKitError.writeStoreReadBackFailed(kind: \"reminder\", undo: .recorded, newIdentifier: unread.committed.newIdentifier(passed: identifier))"))
        let history = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func saveForHistory(_ reminder: EKReminder, handler: String, requested: Set<ReminderFieldCopy.Field> = [],", in: try SourcePins.source("EventKit/ExistingReminderSave.swift"))))
        // String literals are stripped by the pin reader: both cases return, neither throws.
        XCTAssertTrue(history.contains("{ case .readBack: return case .unread: return } }"), history)
    }

    /// PR #507 round 3 MEDIUM 2: the undo record's old state is the write store's copy before the
    /// write, from the first save (the #237 fallback's second save starts from the first commit), in
    /// update_reminder and in complete_reminder's record; the successor comparison keeps `before`.
    func testTheUndoBaselineIsTheWriteStoresCopyBeforeTheWrite() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertEqual(manager.components(separatedBy: "baseline = baseline ?? committed.before").count - 1, 2)
        XCTAssertEqual(manager.components(separatedBy: "let oldSnapshot = ReminderSnapshot(from: reminder)").count - 1, 0)
        XCTAssertTrue(manager.contains("case .readBack(let read, let committed): saved = read baseline = baseline ?? committed.before"))
        let completion = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager+ReminderCompletion.swift")))
        XCTAssertTrue(completion.contains("let (reminder, committed) = try savedOrUnread(original, handler: "))
        XCTAssertTrue(completion.contains("await CalendarUndoManager.shared.record(.forCompletion(before: committed.completionBefore, requestedCompleted: completed, savedTitle: afterSave.title,"))
        XCTAssertTrue(completion.contains("let next = ReminderNextOccurrence.evaluate(before: before, observed: afterSave,"))
    }

    /// PR #507 round 2: the fields the request names reach the copy (update_reminder, completion,
    /// update_calendar), so a value equal to a stale cache is still written.
    func testTheRequestedFieldsReachTheCopy() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(manager.contains("switch try saveExistingReminder(saved, handler: \"updateReminder\", requested: requested, dates: dates)"))
        // Round 4: the #237 fallback's second save passes the fallback's order.
        XCTAssertTrue(manager.contains("save: { try save(dates: .restore) }, saveAgain: { try save(dates: .dueAroundStart) },"))
        XCTAssertTrue(manager.contains("if title != nil { requested.insert(.title) } if color != nil { requested.insert(.cgColor) }"))
        let completion = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager+ReminderCompletion.swift")))
        XCTAssertEqual(completion.components(separatedBy: "requested: ReminderCompletionWrite.requestedFields").count - 1, 3)
    }

}
