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
        let save = try body("func commitReminderSave(_ reminder: EKReminder) throws {", in: file)
        XCTAssertTrue(save.contains("try onWriteStore { store in"), save)
        XCTAssertTrue(save.contains("store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), save)
        XCTAssertTrue(save.contains("try ReminderFieldCopy.apply(from: reminder, to: copy, calendar: { store.calendar(withIdentifier: $0) })"), save)
        XCTAssertTrue(save.contains("try store.save(copy, commit: true)"), save)
        XCTAssertTrue(save.hasSuffix("reminder.rollback() _ = reminder.refresh() }"), save)

        let removal = try body("func commitReminderRemoval(_ reminder: EKReminder) throws {", in: file)
        XCTAssertTrue(removal.contains("try onWriteStore { store in"), removal)
        XCTAssertTrue(removal.contains("as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), removal)
        XCTAssertTrue(removal.contains("try store.remove(copy, commit: true)"), removal)
        XCTAssertTrue(removal.hasSuffix("reminder.rollback() _ = reminder.refresh() }"), removal)

        let list = try body("func commitListSave(_ calendar: EKCalendar) throws {", in: file)
        XCTAssertTrue(list.contains("guard let copy = store.calendar(withIdentifier: calendar.calendarIdentifier) else { throw EventKitError.writeStoreLookupFailed(kind: ) }"), list)
        XCTAssertTrue(list.contains("ListFieldCopy.apply(from: calendar, to: copy)"), list)
        XCTAssertTrue(list.contains("try store.saveCalendar(copy, commit: true)"), list)
        XCTAssertTrue(list.hasSuffix("calendar.rollback() _ = calendar.refresh() }"), list)

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
            .contains("let writeStores = WriteStorePool<EKEventStore>(make: { EKEventStore() })"))
    }
}
