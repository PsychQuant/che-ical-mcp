import XCTest
@testable import CheICalMCP

/// #274: a failed save or removal of an existing reminder stays pending and the next save commits
/// it. It cannot be dropped, so the error says so (measured, see `ExistingReminderSave`).
final class ExistingReminderSaveTests: XCTestCase {
    private struct Failure: Error, Equatable {}
    private struct Reported: Error, Equatable {}

    func testAFailedWriteRollsBackAndReportsTheFailure() {
        var log: [String] = []
        XCTAssertThrowsError(try ExistingReminderSave.run(
            write: { log.append("write"); throw Failure() },
            rollback: { log.append("rollback") },
            report: { error in
                XCTAssertEqual(error as? Failure, Failure())
                log.append("report")
                return Reported()
            })) { error in
            XCTAssertEqual(error as? Reported, Reported())
        }
        XCTAssertEqual(log, ["write", "rollback", "report"])
    }

    func testAWriteThatWorksDoesNothingElse() throws {
        var log: [String] = []
        try ExistingReminderSave.run(write: { log.append("write") }, rollback: { log.append("rollback") },
                                     report: { log.append("report"); return $0 })
        XCTAssertEqual(log, ["write"])
    }

    /// The caller has to learn that an error here does not mean nothing happened.
    func testTheErrorsSayTheChangeMayStillLand() throws {
        let save = try XCTUnwrap(EventKitError.reminderSaveMayLand(code: "eventkit_error_1010").errorDescription)
        XCTAssertTrue(save.contains("eventkit_error_1010"), save)
        XCTAssertTrue(save.contains("may still be written by the next save"), save)
        XCTAssertTrue(save.contains("Read the reminder back before trying again"), save)
        let removal = try XCTUnwrap(EventKitError.reminderRemovalMayLand(code: "eventkit_error_1010").errorDescription)
        XCTAssertTrue(removal.contains("may still be deleted by the next save"), removal)
        XCTAssertTrue(removal.contains("nothing to undo"), removal)
        XCTAssertTrue(removal.contains("Read the reminders back before trying again"), removal)
    }

    /// An undo that fails this way keeps its record: nothing about it is permanent.
    func testAnUndoThatFailsThisWayKeepsItsRecord() {
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.reminderSaveMayLand(code: "x")), .restore)
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.reminderRemovalMayLand(code: "x")), .restore)
    }

    // MARK: - The wiring (no in-memory store can run it)

    /// The direct writes left are the new-object ones, which have their own discard (#261), the
    /// create fallback, and the batch, whose row is bound to a stable code (spec R3).
    func testNoExistingReminderWriteSkipsTheWarning() throws {
        func count(_ needle: String) throws -> [String: Int] {
            var found: [String: Int] = [:]
            for file in try SourceScan.swiftFiles() {
                let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
                let n = code.components(separatedBy: needle).count - 1
                if n > 0 { found[file.lastPathComponent] = n }
            }
            return found
        }
        XCTAssertEqual(try count("ore.save(reminder, commit: true)"), ["EventKitManager.swift": 2, "ExistingReminderSave.swift": 1])
        XCTAssertEqual(try count("ore.remove(reminder, commit: true)"), ["EventKitManager.swift": 1, "ExistingReminderSave.swift": 1])
        XCTAssertEqual(try count("try saveExistingReminder(reminder, handler:"),
                       ["EventKitManager.swift": 4, "EventKitManager+ReminderCompletion.swift": 3])
        XCTAssertEqual(try count("save: { try saveExistingReminder(reminder, handler: \"updateReminder\") }"), ["EventKitManager.swift": 1])
        XCTAssertEqual(try count("try removeExistingReminder(reminder, handler:"), ["EventKitManager.swift": 2])
    }
}
