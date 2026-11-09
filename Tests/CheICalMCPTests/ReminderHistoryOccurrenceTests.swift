import EventKit
import XCTest
@testable import CheICalMCP

/// PR #507 round 5: an undo or redo of a reminder saves on the write store, which fetches the reminder
/// again. The history arms verified the occurrence on the long-lived object only; the copy the write
/// store fetched may already be at the next occurrence (completed elsewhere in between). Each arm now
/// passes the occurrence it verified, and the pre-write check refuses a copy at another one.
final class ReminderHistoryOccurrenceTests: XCTestCase {
    private func occurrence(due day: Int) -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(id: "R", title: "T", calendarID: "C", sourceID: "S", isCompleted: false, hasRecurrence: true,
                                   due: ReminderDueValue(components: DateComponents(year: 2026, month: 11, day: day, hour: 9, minute: 0)),
                                   rules: [ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))],
                                   completionDate: nil)
    }

    /// The long-lived store verified occurrence N (16 Nov); the write store's copy is at N+1 (23 Nov).
    /// Undo (reopen) and redo (complete) are both refused before the write, and nothing is saved.
    func testAnUndoOrRedoWhoseCopyMovedOnWritesNothing() {
        let store = SharedTestStore.store
        for (verb, completed) in [("undo", false), ("redo", true)] {
            let copy = EKReminder(eventStore: store)
            copy.isCompleted = !completed
            var saves = 0
            XCTAssertThrowsError(try ExistingReminderSave.commit(
                lookup: { copy },
                baseline: { _ in self.occurrence(due: 23) },
                check: { try ReminderCompletionWrite.checkSameOccurrence(read: self.occurrence(due: 16), copy: $0) },
                write: { $0.isCompleted = completed },
                save: { _ in saves += 1 })) { error in
                let answered = ExistingReminderSave.historyFailure(error, handler: verb)
                guard case .historyOccurrenceMoved(let v) = answered as? EventKitError else { return XCTFail("\(answered)") }
                XCTAssertEqual(v.rawValue, verb)
                XCTAssertEqual(UndoFailureDisposition.of(answered), .restore, "the entry is kept")
                let text = (answered as? EventKitError)?.errorDescription ?? ""
                XCTAssertTrue(text.hasPrefix("Cannot \(verb): "), text)
                XCTAssertTrue(text.contains("nothing was written"), text)
            }
            XCTAssertEqual(copy.isCompleted, !completed, "\(verb): the copy is not written")
            XCTAssertEqual(saves, 0, "\(verb): nothing is saved")
        }
    }

    func testOtherFailuresPassThroughUnchanged() {
        struct Other: Error {}
        XCTAssertTrue(ExistingReminderSave.historyFailure(Other(), handler: "undo") is Other)
        guard case .writeStoreBusy = ExistingReminderSave.historyFailure(EventKitError.writeStoreBusy, handler: "redo") as? EventKitError else {
            return XCTFail("changed")
        }
    }

    /// Each history arm passes the occurrence it verified: the record's `before` for a recurring
    /// completion, and for the other arms the verified reminder's identity, taken before the record
    /// is applied to it.
    func testEveryHistorySavePassesAnOccurrence() throws {
        let completion = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager+ReminderCompletion.swift")))
        XCTAssertEqual(completion.components(separatedBy: "requested: ReminderCompletionWrite.requestedFields, occurrence: before)").count - 1, 3,
                       "complete_reminder, and the undo and redo of a recurring completion")
        let manager = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertEqual(manager.components(separatedBy: "let occurrence = ReminderCompletionSnapshot(from: reminder) try apply(operation.completionWrite(").count - 1, 2,
                       "the undo and redo of a one-off completion")
        XCTAssertTrue(manager.contains("into: { let verified = try await verifiedReminder(of: operation, verb: .undo); occurrence = ReminderCompletionSnapshot(from: verified); return verified })"))
        XCTAssertTrue(manager.contains("let note = try saveForHistory(reminder, handler: \"undo\", occurrence: occurrence)"))
        let keep = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager+KeepLaterEdits.swift")))
        XCTAssertTrue(keep.contains("let occurrence = ReminderCompletionSnapshot(from: reminder) old.applyRestoring("))
        XCTAssertTrue(keep.contains("let note = try saveForHistory(reminder, handler: \"undo\", occurrence: occurrence)"))
        let save = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/ExistingReminderSave.swift")))
        XCTAssertTrue(save.contains("occurrence: ReminderCompletionSnapshot?) throws -> String {"), "the occurrence has no default")
        XCTAssertTrue(save.contains("} catch { throw ExistingReminderSave.historyFailure(error, handler: handler) }"))
    }

    // MARK: - Round 6

    /// The refusal keeps the entry, so it says how to give it up (#269's path): a check that misfires
    /// on every try would otherwise pin the undo stack.
    func testTheRefusalSaysHowToGiveTheEntryUp() {
        let undo = EventKitError.historyOccurrenceMoved(verb: .undo).errorDescription ?? ""
        XCTAssertTrue(undo.contains("To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."), undo)
        let redo = EventKitError.historyOccurrenceMoved(verb: .redo).errorDescription ?? ""
        XCTAssertTrue(redo.contains("To go on, ask the user whether to give up this redo; any new change clears the redo history."), redo)
        // Round 6 INFO: one side may repeat only (a rule added or removed elsewhere), so not "repeating".
        XCTAssertFalse(undo.contains("this repeating reminder"), undo)
        XCTAssertFalse((EventKitError.completionOccurrenceMoved.errorDescription ?? "").contains("this repeating reminder"))
    }

    /// The docs and both tool descriptions say an undo or redo is refused when the reminder moved on.
    func testTheDocsNameTheHistoryRefusal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        let en = "An undo or redo of an update_reminder, a keep_later_edits merge or a completion is refused the same way, with the entry kept."
        for name in ["CHANGELOG.md", "README.md"] {
            XCTAssertEqual(try read(name).components(separatedBy: en).count - 1, 1, name)
        }
        XCTAssertEqual(try read("README_zh-TW.md").components(separatedBy: "update_reminder、keep_later_edits 合併或完成的 undo 與 redo 遇到同樣情況也會被拒絕，紀錄保留。").count - 1, 1)
        let server = try SourcePins.source("Server.swift")
        XCTAssertEqual(server.components(separatedBy: "is no longer at the occurrence it was checked at (completed or changed elsewhere in between) is refused with nothing written and the entry kept").count - 1, 2,
                       "undo and redo")
        let manifest = try read("mcpb/manifest.json")
        XCTAssertEqual(manifest.components(separatedBy: "a reminder that moved to another occurrence in between is refused, nothing written, entry kept").count - 1, 2)
    }

    // MARK: - LOWs

    func testTheChangelogDoesNotSayADueChangeWritesTheZone() throws {
        let log = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        XCTAssertFalse(log.contains("which writes start, zone and the absolute alarms"))
    }

    func testTheBatchDescriptionsSayAStoreWithNoDataRefusesTheCall() throws {
        let server = try SourcePins.source("Server.swift")
        XCTAssertFalse(server.contains("when every store is in use at the first row"))
        XCTAssertEqual(server.components(separatedBy: "until a row has been deleted, a store that is busy or sees no data refuses the whole call (writeStoreBusy)").count - 1, 2)
    }
}
