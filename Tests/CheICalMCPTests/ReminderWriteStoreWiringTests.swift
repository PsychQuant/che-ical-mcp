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
        let save = try body("func commitReminderSave(_ reminder: EKReminder) throws -> EKReminder? {", in: file)
        XCTAssertTrue(save.contains("try onWriteStore { store in"), save)
        XCTAssertTrue(save.contains("store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), save)
        XCTAssertTrue(save.contains("try ReminderFieldCopy.apply(wanted, fields: fields, to: copy, calendar: { store.calendar(withIdentifier: $0) })"), save)
        XCTAssertTrue(save.contains("try store.save(copy, commit: true)"), save)

        let removal = try body("func commitReminderRemoval(_ reminder: EKReminder) throws {", in: file)
        XCTAssertTrue(removal.contains("try onWriteStore { store in"), removal)
        XCTAssertTrue(removal.contains("as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), removal)
        XCTAssertTrue(removal.contains("try store.remove(copy, commit: true)"), removal)
        XCTAssertTrue(removal.hasSuffix("reminder.rollback() _ = reminder.refresh() }"), removal)

        let list = try body("func commitListSave(_ calendar: EKCalendar) throws -> Bool {", in: file)
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
        XCTAssertTrue(batch.contains("try commitReminderRemoval(reminder)"), batch)
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
        let save = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func saveExistingReminder(_ reminder: EKReminder, handler: String) throws -> EKReminder {", in: source)))
        XCTAssertTrue(save.contains("guard let saved else {"), save)
        XCTAssertTrue(save.contains("throw EventKitError.writeStoreReadBackFailed(kind: "), save)
        let list = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func saveExistingCalendar(_ calendar: EKCalendar) throws {", in: source)))
        XCTAssertTrue(list.contains("guard readBack else {"), list)
        let commitList = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitListSave(_ calendar: EKCalendar) throws -> Bool {", in: source)))
        XCTAssertTrue(commitList.hasSuffix("return calendar.refresh() }"), commitList)
        // A removal's refresh is false by design (the item is gone); a save's is the read-back.
        let commitSave = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder) throws -> EKReminder? {", in: source)))
        XCTAssertFalse(commitSave.contains("_ = reminder.refresh()"), commitSave)
        XCTAssertFalse(commitList.contains("_ = calendar.refresh()"), commitList)
    }

    /// The HIGH: the identifier comes off the write store's copy after its save, and a different one
    /// is resolved again on this server's store.
    func testTheSavedIdentifierComesOffTheCopyAndIsResolvedAgain() throws {
        let source = try SourcePins.source("EventKit/ExistingReminderSave.swift")
        let commit = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder) throws -> EKReminder? {", in: source)))
        XCTAssertTrue(commit.contains("try store.save(copy, commit: true) return copy.calendarItemIdentifier }"), commit)
        XCTAssertTrue(commit.hasSuffix("return resolvedAfterSave(reminder, savedID: savedID) }"), commit)
        let resolve = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func resolvedAfterSave(_ reminder: EKReminder, savedID: String) -> EKReminder? {", in: source)))
        XCTAssertTrue(resolve.contains("if savedID == reminder.calendarItemIdentifier { return reminder.refresh() ? reminder : nil }"), resolve)
        XCTAssertTrue(resolve.contains("eventStore.calendarItem(withIdentifier: savedID) as? EKReminder, moved.refresh()"), resolve)
    }

    /// The changed fields are taken against the caller's object rolled back, before the write store
    /// is touched, so no field the call left alone reaches the copy.
    func testTheChangeIsTakenAgainstTheRolledBackObject() throws {
        let source = try SourcePins.source("EventKit/ExistingReminderSave.swift")
        let commit = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitReminderSave(_ reminder: EKReminder) throws -> EKReminder? {", in: source)))
        XCTAssertTrue(commit.contains("let wanted = ReminderFieldCopy.Values(reminder) reminder.rollback() let fields = ReminderFieldCopy.changed(from: ReminderFieldCopy.Values(reminder), to: wanted)"), commit)
        XCTAssertTrue(commit.contains("try ReminderFieldCopy.apply(wanted, fields: fields, to: copy,"), commit)
        let list = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func commitListSave(_ calendar: EKCalendar) throws -> Bool {", in: source)))
        XCTAssertTrue(list.contains("let wanted = ListFieldCopy.Values(calendar) calendar.rollback() let fields = ListFieldCopy.changed(from: ListFieldCopy.Values(calendar), to: wanted)"), list)
        XCTAssertTrue(list.contains("ListFieldCopy.apply(wanted, fields: fields, to: copy)"), list)
    }

    /// update_reminder reads back, answers and records the reminder the save left behind, so a move
    /// that changed the identifier is answered and recorded under the new one.
    func testUpdateReminderUsesTheReminderTheSaveLeftBehind() throws {
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(manager.contains("var saved = reminder let dateSync = try ReminderUpdateWrite.apply("), "update_reminder")
        XCTAssertTrue(manager.contains("reload: { saved.refresh() }, rollback: { saved.rollback() }, current: { saved })"))
        XCTAssertTrue(manager.contains("reminder: ReminderWriteSnapshot(from: saved), dateSync: dateSync"))
        XCTAssertTrue(manager.contains("let savedID = saved.calendarItemIdentifier await CalendarUndoManager.shared.record(.updateReminder(id: savedID, oldSnapshot: oldSnapshot, saved: postWriteSnapshot(reminderID: savedID, saved: saved)))"))
        let write = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/ReminderUpdateWrite.swift")))
        XCTAssertTrue(write.contains("return ReminderDateSync.confirmSaved(current?() ?? reminder, report: dateSync,"))
    }

}
