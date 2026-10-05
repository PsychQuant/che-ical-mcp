import CheMCPKit
import EventKit
import XCTest
@testable import CheICalMCP

/// #236, maintainer decision after PR #259 round 4: undo of an `update_event` that touched a
/// recurring event is refused, never attempted. Every restore strategy had store-dependent ways to
/// move, detach or delete occurrences, so the record is kept only as a marker; undo on it writes
/// nothing and discards it, as #204 does, so earlier operations stay undoable.
final class RecurringUpdateUndoTests: XCTestCase {
    private func kind(hadRules: Bool, after: Bool, onOccurrence: Bool = false, span: EKSpan = .thisEvent) -> RecurringUpdateKind? {
        RecurringUpdateKind.of(hadRules: hadRules, hasRulesAfter: after, onOccurrence: onOccurrence, span: span)
    }

    func testAnUpdateOfAOneOffEventIsNotARecurringUpdate() {
        XCTAssertNil(kind(hadRules: false, after: false))
        XCTAssertNil(kind(hadRules: false, after: false, span: .futureEvents))
    }

    func testWhichUpdatesTouchedARecurringEvent() {
        XCTAssertEqual(kind(hadRules: true, after: true, onOccurrence: true), .occurrence, "span this with occurrence_date")
        XCTAssertEqual(kind(hadRules: true, after: true, onOccurrence: true, span: .futureEvents), .future, "span future")
        XCTAssertEqual(kind(hadRules: false, after: true), .rulesAdded, "a one-off event made to repeat")
        XCTAssertEqual(kind(hadRules: true, after: false, span: .futureEvents), .rulesRemoved, "clear_recurrence on the series")
        XCTAssertEqual(kind(hadRules: true, after: false, onOccurrence: true), .rulesRemoved, "rules removed wins over where they were removed")
    }

    /// #262: span "all" (the series saved with .futureEvents). Its undo saved the first occurrence
    /// alone, which on iCloud detached it and deleted the rest of the series; it is refused too.
    func testASeriesUpdateIsARecurringUpdate() {
        XCTAssertEqual(kind(hadRules: true, after: true, span: .futureEvents), .series)
        XCTAssertEqual(kind(hadRules: true, after: true), .series, "the series however it was saved")
        let message = EventKitErrorSanitizer.sanitizeForResponse(UndoOperation.recurringUpdateRefusal(title: "Standup", kind: .series)).code
        XCTAssertTrue(message.contains("the whole series"), message)
    }

    /// Round 5 findings 3, 4, 6, 9, 37: a detached occurrence addressed by its own identifier
    /// reads back with no rules, but updating it is an occurrence update.
    func testAnUpdateOfADetachedOccurrenceIsAnOccurrenceUpdate() {
        XCTAssertEqual(kind(hadRules: false, after: false, onOccurrence: true), .occurrence)
        XCTAssertEqual(kind(hadRules: false, after: true, onOccurrence: true), .occurrence, "rules in the request do not make it a one-off")
    }

    // MARK: - The undo arm (round 5 findings 1, 2, 5, 7)

    /// The undo of a one-off update never writes to an event that repeats or is an edited
    /// occurrence now, however it got there (a later update that added rules, whose marker was
    /// already discarded, or another app). Checked after resolve and refresh, before any write.
    func testUndoOfAOneOffUpdateRefusesAnEventThatRepeatsNow() throws {
        let update = UndoOperation.updateEvent(id: "e", oldSnapshot: UndoSnapshotFixtures.event(title: "Standup"),
                                               saved: UndoSnapshotFixtures.event(title: "Standup (renamed)"))
        XCTAssertNil(update.recurringTargetRefusal(hasRecurrenceRules: false, isDetached: false), "still a one-off: undo goes ahead")

        for (rules, detached, reason) in [(true, false, "repeats now"), (false, true, "edited occurrence")] {
            let error = try XCTUnwrap(update.recurringTargetRefusal(hasRecurrenceRules: rules, isDetached: detached))
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
            let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
            XCTAssertTrue(message.hasPrefix("Cannot undo the update of the event 'Standup'"), message)
            XCTAssertTrue(message.contains(reason), message)
            XCTAssertTrue(message.contains("Nothing was written"), message)
            XCTAssertTrue(message.contains("revert it in Calendar"), message)
            XCTAssertFalse(message.contains("discard_id"), message)
        }
    }

    /// Only the update arm restores a snapshot onto an existing event; other records are not
    /// affected by this check.
    func testOtherRecordsAreNotAffected() {
        let create = UndoOperation.createEvent(id: "e", title: "Standup", created: UndoSnapshotFixtures.event(title: "Standup"))
        XCTAssertNil(create.recurringTargetRefusal(hasRecurrenceRules: true, isDetached: false))
    }

    func testTheRecordIsAMarkerWithNothingToCompareOrWrite() {
        let op = UndoOperation.updateRecurringEvent(id: "series/RID=1", title: "Standup", kind: .occurrence)
        XCTAssertNil(op.undoPostState, "nothing is compared, because nothing is written")
        XCTAssertNil(op.redoPostState)
        XCTAssertEqual(op.description, "Updated recurring event: Standup (undo not available)")
    }

    /// Round 5 finding 20: the marker's undo_history and redo text show the title like the errors.
    func testTheMarkerShowsItsTitleLikeTheErrors() {
        let op = UndoOperation.updateRecurringEvent(id: "e", title: "Stand\u{202E}up\u{200B} 'x'", kind: .series)
        XCTAssertEqual(op.description, "Updated recurring event: Standup \u{2019}x\u{2019} (undo not available)")
    }

    func testUndoIsRefusedPermanentlyAndNamesTheReason() {
        let reasons: [RecurringUpdateKind: String] = [
            .occurrence: "one occurrence", .future: "following occurrences",
            .rulesAdded: "made a one-off event repeat", .rulesRemoved: "removed the event's repetition",
        ]
        for (kind, reason) in reasons {
            let error = UndoOperation.recurringUpdateRefusal(title: "Standup\u{202E}", kind: kind)
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard, "\(kind): discarded so earlier operations stay undoable")
            let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
            XCTAssertTrue(message.hasPrefix("Cannot undo the update of the recurring event 'Standup'"), message)
            XCTAssertTrue(message.contains(reason), "\(kind): \(message)")
            XCTAssertTrue(message.contains("Nothing was written"), message)
            XCTAssertTrue(message.contains("revert it in Calendar"), message)
            XCTAssertTrue(message.contains("earlier operations remain undoable"), message)
            XCTAssertFalse(message.contains("discard_id"), "the entry is already discarded")
        }
    }
}
