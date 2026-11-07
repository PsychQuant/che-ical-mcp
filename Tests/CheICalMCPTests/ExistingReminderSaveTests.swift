import EventKit
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

    /// A commit failure, as the probe saw it: not in `EKErrorDomain`.
    private let commitFailure = NSError(domain: "EKCADErrorDomain", code: 1010)

    /// The caller has to learn that an error here does not mean nothing happened.
    func testACommitFailureSaysItMayLandWithTheLoggedCode() throws {
        var logged: [NSError] = []
        func code(_ error: Error) -> String { logged.append(error as NSError); return "code-from-the-log" }
        let save = ExistingReminderSave.saveFailure(commitFailure, code: code)
        guard case EventKitError.reminderSaveMayLand(code: "code-from-the-log") = save else { return XCTFail("\(save)") }
        let removal = ExistingReminderSave.removalFailure(commitFailure, code: code)
        guard case EventKitError.reminderRemovalMayLand(code: "code-from-the-log") = removal else { return XCTFail("\(removal)") }
        let list = ExistingReminderSave.listChangeFailure(commitFailure, code: code)
        guard case EventKitError.listChangeMayLand(code: "code-from-the-log") = list else { return XCTFail("\(list)") }
        let listRemoval = ExistingReminderSave.listRemovalFailure(commitFailure, code: code)
        guard case EventKitError.listRemovalMayLand(code: "code-from-the-log") = listRemoval else { return XCTFail("\(listRemoval)") }
        XCTAssertEqual(logged.count, 4)
    }

    /// Measured to leave nothing pending, so no warning: EKErrorDomain 18, 23, 26. The list is closed.
    func testARefusalAtValidationAnswersAsItself() {
        for code in [18, 23, 26] {
            let refused = NSError(domain: EKErrorDomain, code: code)
            var logged = false
            let answer = ExistingReminderSave.saveFailure(refused) { _ in logged = true; return "x" }
            XCTAssertEqual(answer as NSError, refused, "\(code)")
            XCTAssertFalse(logged, "\(code)")
        }
        XCTAssertEqual(ExistingReminderSave.refusedAtValidation, [18, 23, 26])
    }

    func testAnyOtherFailureOfASaveKeepsTheWarning() {
        for failure in [NSError(domain: EKErrorDomain, code: 6), NSError(domain: EKErrorDomain, code: 1),
                        NSError(domain: "other", code: 18), commitFailure] {
            guard case EventKitError.reminderSaveMayLand = ExistingReminderSave.saveFailure(failure, code: { _ in "x" }) else {
                return XCTFail("\(failure)")
            }
        }
    }

    /// No removal was refused at validation in any shape tried, so a removal always warns.
    func testARemovalAlwaysWarns() {
        guard case EventKitError.reminderRemovalMayLand = ExistingReminderSave.removalFailure(NSError(domain: EKErrorDomain, code: 18), code: { _ in "x" }) else {
            return XCTFail("a removal warns")
        }
    }

    func testTheErrorsSayTheChangeMayStillLand() throws {
        let save = try XCTUnwrap(EventKitError.reminderSaveMayLand(code: "error_unknown").errorDescription)
        XCTAssertTrue(save.contains("error_unknown"), save)
        XCTAssertTrue(save.contains("may still be written by the next save"), save)
        let removal = try XCTUnwrap(EventKitError.reminderRemovalMayLand(code: "error_unknown").errorDescription)
        XCTAssertTrue(removal.contains("may still be deleted by the next save"), removal)
        let list = try XCTUnwrap(EventKitError.listChangeMayLand(code: "error_unknown").errorDescription)
        XCTAssertTrue(list.contains("may still be written by the next save"), list)
        let listRemoval = try XCTUnwrap(EventKitError.listRemovalMayLand(code: "error_unknown").errorDescription)
        XCTAssertTrue(listRemoval.contains("the list and every reminder in it may still be deleted"), listRemoval)
        for message in [save, removal, listRemoval] {
            XCTAssertTrue(message.contains("no undo record of its own"), message)
        }
    }

    /// What a read shows before the next save was not measured, and `saveUnchecked` says a check
    /// right away proves nothing, so none of these may send the caller to a read as the way out.
    func testAReadBackDoesNotClearTheWarning() throws {
        let texts = [EventKitError.reminderSaveMayLand(code: "x"), .reminderRemovalMayLand(code: "x"),
                     .listChangeMayLand(code: "x"), .listRemovalMayLand(code: "x")].compactMap(\.errorDescription)
            + [BatchDeleteResult.failedRowsNote]
        XCTAssertEqual(texts.count, 5)
        for text in texts {
            XCTAssertTrue(text.contains("back now does not rule this out"), text)
            XCTAssertFalse(text.contains("before trying"), text)
            XCTAssertFalse(text.contains("nothing to undo"), text)
        }
    }

    func testTheBatchNoteCoversThisCallAndUndo() {
        XCTAssertTrue(BatchDeleteResult.failedRowsNote.contains("may already be deleted by a later row of this call"))
        XCTAssertTrue(BatchDeleteResult.failedRowsNote.contains("no undo record of their own"))
    }

    /// A change an undo finds can be this server's own failed write, landed later, whichever call
    /// made it. Only reminders do that.
    func testAnUndoRefusalNamesThisServersFailedWriteForRemindersOnly() throws {
        let reminder = try XCTUnwrap(UndoTargetChangedError(verb: .undo, kind: .reminder, title: "t", changedFields: ["title"]).errorDescription)
        XCTAssertTrue(reminder.contains("by a failed write of this server that landed later"), reminder)
        let event = try XCTUnwrap(UndoTargetChangedError(verb: .undo, kind: .event, title: "t", changedFields: ["title"]).errorDescription)
        XCTAssertFalse(event.contains("failed write"), event)
    }

    /// The #237 fallback catches this error, and its log keeps the code.
    func testTheFallbackLogKeepsTheCode() {
        XCTAssertEqual(EventKitError.reminderSaveMayLand(code: "eventkit_error_5").mayLandCode, "eventkit_error_5")
        XCTAssertNil(EventKitError.reminderRemovalMayLand(code: "x").mayLandCode)
    }

    /// The closures the tests above cannot reach: each wrapper answers with its own failure, and the
    /// code comes from the sanitizer's log. Swapping two of these, or `{ $0 }`, goes red here.
    func testEachWrapperReportsItsOwnFailureThroughTheLog() throws {
        for (declaration, failure) in [("func saveExistingReminder(_ reminder: EKReminder, handler: String) throws {", "saveFailure"),
                                       ("func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {", "removalFailure"),
                                       ("func saveExistingCalendar(_ calendar: EKCalendar) throws {", "listChangeFailure"),
                                       ("func removeExistingCalendar(_ calendar: EKCalendar) throws {", "listRemovalFailure")] {
            let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source("EventKit/ExistingReminderSave.swift")), declaration))
            XCTAssertTrue(body.contains("report: { failure in ExistingReminderSave.\(failure)(failure) { EventKitErrorSanitizer.writeFailureLog("), body)
        }
    }

    /// Each wrapper performs its own write: swapping a save and a remove goes red here.
    func testEachWrapperPerformsItsOwnWrite() throws {
        for (declaration, write) in [("func saveExistingReminder(_ reminder: EKReminder, handler: String) throws {", "try eventStore.save(reminder, commit: true)"),
                                     ("func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {", "try eventStore.remove(reminder, commit: true)"),
                                     ("func saveExistingCalendar(_ calendar: EKCalendar) throws {", "try eventStore.saveCalendar(calendar, commit: true)"),
                                     ("func removeExistingCalendar(_ calendar: EKCalendar) throws {", "try eventStore.removeCalendar(calendar, commit: true)")] {
            let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source("EventKit/ExistingReminderSave.swift")), declaration))
            XCTAssertTrue(body.contains("write: { \(write) }"), body)
            if declaration.contains("Calendar") {
                XCTAssertTrue(body.contains("return \(write) }"), "the event calendar path: \(body)")
            }
        }
    }

    /// An event calendar goes straight through, because its failed save left nothing pending. Only
    /// that: a calendar reporting neither kind keeps the warning.
    func testOnlyAReminderListTakesTheWarning() throws {
        for declaration in ["func saveExistingCalendar(_ calendar: EKCalendar) throws {", "func removeExistingCalendar(_ calendar: EKCalendar) throws {"] {
            let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source("EventKit/ExistingReminderSave.swift")), declaration))
            XCTAssertTrue(body.contains("guard calendar.allowedEntityTypes != .event else { return try eventStore."), body)
        }
        let manager = SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift"))
        XCTAssertTrue(manager.contains("try saveExistingCalendar(calendar)"))
        XCTAssertTrue(manager.contains("try removeExistingCalendar(calendar)"))
    }

    /// An undo that fails this way keeps its record: nothing about it is permanent.
    func testAnUndoThatFailsThisWayKeepsItsRecord() {
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.reminderSaveMayLand(code: "x")), .restore)
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.reminderRemovalMayLand(code: "x")), .restore)
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.listRemovalMayLand(code: "x")), .restore)
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
