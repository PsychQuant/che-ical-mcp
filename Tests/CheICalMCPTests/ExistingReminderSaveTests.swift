import EventKit
import XCTest
@testable import CheICalMCP

/// #274 / #459: a save or removal of an existing reminder or reminder list. Since #459 it commits on
/// a separate write store, so a failure is dropped with that store and is reported as itself: it no
/// longer stays pending in the long-lived store (measured, see `WriteStorePool`).
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

    /// A failure on the write store did not land, so it answers as itself; its code is still logged.
    func testAFailureIsReportedAsItselfWithItsCodeLogged() {
        for failure in [NSError(domain: "EKCADErrorDomain", code: 1010), NSError(domain: EKErrorDomain, code: 18),
                        NSError(domain: EKErrorDomain, code: 6)] {
            var logged: [NSError] = []
            let answer = ExistingReminderSave.failure(failure) { logged.append($0 as NSError); return "x" }
            XCTAssertEqual(answer as NSError, failure)
            XCTAssertEqual(logged, [failure])
        }
    }

    /// The four may-land errors and the batch note are gone: no reminder or list write warns that a
    /// failure may still land, since none can.
    func testNoWriteSaysAFailureMayStillLand() throws {
        let manager = SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift"))
        for gone in ["reminderSaveMayLand", "reminderRemovalMayLand", "listChangeMayLand", "listRemovalMayLand",
                     "failedRowsNote", "mayLandCount", "mayLandCode"] {
            XCTAssertFalse(manager.contains(gone), gone)
        }
        let server = try SourcePins.source("Server.swift")
        XCTAssertFalse(server.contains("next save this server makes"))
        XCTAssertFalse(server.contains("failed_rows_note"))
    }

    func testTheWriteStoreErrorsSayNothingWasWritten() throws {
        let busy = try XCTUnwrap(EventKitError.writeStoreBusy.errorDescription)
        XCTAssertTrue(busy.hasPrefix("Nothing was written"), busy)
        XCTAssertTrue(busy.contains("4 separate stores"), busy)
        let blind = try XCTUnwrap(EventKitError.writeStoreLookupFailed(kind: "reminder").errorDescription)
        XCTAssertTrue(blind.hasPrefix("Nothing was written"), blind)
        XCTAssertTrue(blind.contains("This is a store error, not a missing reminder"), blind)
        XCTAssertFalse(blind.lowercased().contains("not found"), "never reported as not found: \(blind)")
    }

    /// A change an undo finds can still be this server's own failed write, landed later: the
    /// create's second save (#237) stays on the long-lived store. Only reminders do that.
    func testAnUndoRefusalNamesThisServersFailedWriteForRemindersOnly() throws {
        let reminder = try XCTUnwrap(UndoTargetChangedError(verb: .undo, kind: .reminder, title: "t", changedFields: ["title"]).errorDescription)
        XCTAssertTrue(reminder.contains("by a failed write of this server that landed later"), reminder)
        let event = try XCTUnwrap(UndoTargetChangedError(verb: .undo, kind: .event, title: "t", changedFields: ["title"]).errorDescription)
        XCTAssertFalse(event.contains("failed write"), event)
    }

    /// The closures the tests above cannot reach: each wrapper logs its failure through the
    /// sanitizer's log and answers with it.
    func testEachWrapperReportsItsOwnFailureThroughTheLog() throws {
        for declaration in ["func saveExistingReminder(_ reminder: EKReminder, handler: String, requested: Set<ReminderFieldCopy.Field> = []) throws -> ReminderSaveOutcome {",
                            "func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {",
                            "func saveExistingCalendar(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {",
                            "func removeExistingCalendar(_ calendar: EKCalendar) throws {"] {
            let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source("EventKit/ExistingReminderSave.swift")), declaration))
            XCTAssertTrue(body.contains("report: { failure in ExistingReminderSave.failure(failure) { EventKitErrorSanitizer.writeFailureLog("), body)
        }
    }

    /// Each wrapper performs its own write, on the write store: swapping a save and a remove goes red.
    func testEachWrapperPerformsItsOwnWrite() throws {
        for (declaration, write) in [("func saveExistingReminder(_ reminder: EKReminder, handler: String, requested: Set<ReminderFieldCopy.Field> = []) throws -> ReminderSaveOutcome {", "outcome = try commitReminderSave(reminder, requested: requested)"),
                                     ("func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {", "try commitReminderRemoval(reminder)"),
                                     ("func saveExistingCalendar(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {", "readBack = try commitListSave(calendar, requested: requested)"),
                                     ("func removeExistingCalendar(_ calendar: EKCalendar) throws {", "try commitListRemoval(calendar)")] {
            let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source("EventKit/ExistingReminderSave.swift")), declaration))
            XCTAssertTrue(body.contains("write: { \(write) }"), body)
        }
    }

    /// An event calendar goes straight through the long-lived store, as every event write does.
    func testOnlyAReminderListGoesThroughTheWriteStore() throws {
        for (declaration, direct) in [("func saveExistingCalendar(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {", "try eventStore.saveCalendar(calendar, commit: true) return true"),
                                      ("func removeExistingCalendar(_ calendar: EKCalendar) throws {", "return try eventStore.removeCalendar(calendar, commit: true)")] {
            let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source("EventKit/ExistingReminderSave.swift")), declaration))
            XCTAssertTrue(body.contains("guard calendar.allowedEntityTypes != .event else { \(direct) }"), body)
        }
        let manager = SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift"))
        XCTAssertTrue(manager.contains("let readBack = try saveExistingCalendar(calendar, requested: requested)"))
        XCTAssertTrue(manager.contains("try removeExistingCalendar(calendar)"))
    }

    /// An undo that fails on the write store keeps its record: nothing about it is permanent.
    func testAnUndoThatFailsThisWayKeepsItsRecord() {
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.writeStoreBusy), .restore)
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.writeStoreLookupFailed(kind: "reminder")), .restore)
        XCTAssertEqual(UndoFailureDisposition.of(NSError(domain: "EKCADErrorDomain", code: 1010)), .restore)
    }

    // MARK: - The wiring (no in-memory store can run it)

    /// The direct writes of a reminder left on the long-lived store are the new-object ones, which
    /// have their own discard (#261), and the create's second save (#237). Every existing-reminder
    /// write goes through a wrapper, and the batch through the write store's removal.
    func testNoExistingReminderWriteBypassesTheWriteStore() throws {
        func count(_ needle: String) throws -> [String: Int] {
            var found: [String: Int] = [:]
            for file in try SourceScan.swiftFiles() {
                let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
                let n = code.components(separatedBy: needle).count - 1
                if n > 0 { found[file.lastPathComponent] = n }
            }
            return found
        }
        XCTAssertEqual(try count("eventStore.save(reminder, commit: true)"), ["EventKitManager.swift": 2])
        XCTAssertEqual(try count("eventStore.remove(reminder, commit: true)"), [:])
        XCTAssertEqual(try count("ore.remove(reminder, commit: false)"), ["EventKitManager.swift": 1])
        // PR #507 round 2: undo and redo save through `saveForHistory`, a completion through
        // `savedOrUnread`, update_reminder through its own closure; all three call the one wrapper.
        XCTAssertEqual(try count("try saveForHistory(reminder, handler:"),
                       ["EventKitManager.swift": 3, "EventKitManager+ReminderCompletion.swift": 2,
                        // #265: the merge arm of `undo` with keep_later_edits.
                        "EventKitManager+KeepLaterEdits.swift": 1])
        XCTAssertEqual(try count("try savedOrUnread(original, handler: \"completeReminder\""), ["EventKitManager+ReminderCompletion.swift": 1])
        XCTAssertEqual(try count("switch try saveExistingReminder(saved, handler: \"updateReminder\", requested: requested)"), ["EventKitManager.swift": 1])
        XCTAssertEqual(try count("try saveExistingReminder("), ["EventKitManager.swift": 1, "ExistingReminderSave.swift": 2])
        XCTAssertEqual(try count("try removeExistingReminder(reminder, handler:"), ["EventKitManager.swift": 2])
        XCTAssertEqual(try count("try commitReminderRemoval(reminder)"), ["EventKitManager.swift": 1, "ExistingReminderSave.swift": 1])
    }

    /// PR #507 round 2 (HIGH): a save that landed but could not be read back says what happened to
    /// its undo: recorded (a reminder, from the write store's copy), or a refusing marker (a list).
    func testAFailedReadBackSaysWhereItsUndoIs() {
        let recorded = EventKitError.writeStoreReadBackFailed(kind: "reminder", undo: .recorded).errorDescription ?? ""
        XCTAssertTrue(recorded.hasPrefix("The change was saved"), recorded)
        XCTAssertTrue(recorded.contains("Its undo record was kept, so undo reverts this change."), recorded)
        let marker = EventKitError.writeStoreReadBackFailed(kind: "reminder list", undo: .refusingMarker).errorDescription ?? ""
        XCTAssertTrue(marker.contains("undo refuses it instead of reverting an older operation"), marker)
    }

    /// PR #507 round 2 (LOW 5, INFO 8): the busy text names the store that sees no data, and the
    /// lookup text says the item may not be committed yet.
    func testTheStoreTextsNameTheirOtherCause() {
        let busy = EventKitError.writeStoreBusy.errorDescription ?? ""
        XCTAssertTrue(busy.contains("or a new one could not see any data"), busy)
        let lookup = EventKitError.writeStoreLookupFailed(kind: "reminder").errorDescription ?? ""
        XCTAssertTrue(lookup.contains("may not be committed yet"), lookup)
    }
}
