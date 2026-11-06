import XCTest
@testable import CheICalMCP

/// #274: a failed save of an existing reminder stays pending in the store and the next save writes
/// it, and `EKObject.rollback()` does not stop that (measured, see `ExistingReminderSave`).
final class ExistingReminderSaveTests: XCTestCase {
    private struct Failure: Error, Equatable {}

    func testAFailedSaveDiscardsThenRethrows() {
        var log: [String] = []
        XCTAssertThrowsError(try ExistingReminderSave.run(
            save: { log.append("save"); throw Failure() },
            discard: { log.append("discard") })) { error in
            XCTAssertEqual(error as? Failure, Failure())
        }
        XCTAssertEqual(log, ["save", "discard"])
    }

    func testASaveThatWorksDiscardsNothing() throws {
        var log: [String] = []
        try ExistingReminderSave.run(save: { log.append("save") }, discard: { log.append("discard") })
        XCTAssertEqual(log, ["save"])
    }

    // MARK: - The wiring (no in-memory store can run it)

    private func flat(_ declaration: String, in file: String) throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source(file)), declaration))
    }

    /// The object's rollback alone is the thing that did not work, so the store's reset must follow
    /// it, and the refresh comes last: until then the object holds the failed values.
    func testTheDiscardResetsTheStoreAndReadsTheObjectBack() throws {
        let body = try flat("func discardFailedSave(of reminder: EKReminder) {", in: "EventKit/ExistingReminderSave.swift")
        XCTAssertTrue(body.contains("{ reminder.rollback() eventStore.reset() _ = reminder.refresh() markNeedsRefresh() }"), body)
    }

    func testTheSaveGoesThroughTheSeam() throws {
        let body = try flat("func saveExistingReminder(_ reminder: EKReminder) throws {", in: "EventKit/ExistingReminderSave.swift")
        XCTAssertTrue(body.contains("{ try ExistingReminderSave.run(save: { try eventStore.save(reminder, commit: true) }, discard: { discardFailedSave(of: reminder) }) }"), body)
    }

    /// Every save of a reminder already in the store: a direct one here would be a write the next
    /// save could repeat. The new-object save has its own discard (#261), and `update_reminder` and
    /// the create fallback hand their seams the same discard.
    func testNoReminderSaveBypassesTheDiscard() throws {
        var saves: [String: Int] = [:]
        for file in try SourceScan.swiftFiles() {
            let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
            let count = code.components(separatedBy: "ore.save(reminder, commit: true)").count - 1
            if count > 0 { saves[file.lastPathComponent] = count }
        }
        XCTAssertEqual(saves, ["EventKitManager.swift": 3, "ExistingReminderSave.swift": 1], "\(saves)")

        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        let completion = try SourcePins.source("EventKit/EventKitManager+ReminderCompletion.swift")
        for (code, count) in [(manager, 3), (completion, 3)] {
            XCTAssertEqual(code.components(separatedBy: "try saveExistingReminder(reminder)").count - 1, count)
        }
        XCTAssertEqual(manager.components(separatedBy: "rollback: { discardFailedSave(of: reminder) }").count - 1, 2)
        XCTAssertFalse(SourceScan.strippingComments(manager).contains("reminder.rollback()"))
    }
}
