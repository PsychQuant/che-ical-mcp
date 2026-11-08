import XCTest
@testable import CheICalMCP

/// #287: a batch undo the pre-check refuses (#248 B) can, when the caller asks with
/// `restore_available`, restore the members whose calendar or list is in place and keep only the
/// others, under the same id, as a part-way failure has been kept since #248 A. The split and the
/// order of the steps are pure (closure seam), so they are tested here without EventKit. The
/// members are the kinds the batch tools record: deleted events (`delete_events_batch`), deleted
/// occurrences (#244) and deleted reminders (`delete_reminders_batch` and
/// `cleanup_completed_reminders`, which record the same `.batch` of `.deleteReminder`).
final class UndoBatchPartialRestoreTests: XCTestCase {
    private let a = UndoSnapshotFixtures.event(title: "A")
    private let b = UndoSnapshotFixtures.event(title: "B", calendarTitle: "Private calendar title")
    private let c = UndoSnapshotFixtures.reminder(title: "C")
    private let d = UndoSnapshotFixtures.reminder(title: "D")
    private let e = UndoSnapshotFixtures.event(title: "E")

    private var members: [UndoOperation] {
        [.deleteEvent(snapshot: a), .deleteEvent(snapshot: b), .deleteReminder(snapshot: c), .deleteReminder(snapshot: d),
         .deleteOccurrence(snapshot: e, notCarriedOver: [])]
    }

    /// B's calendar is gone and D's list is read-only; the others are in place.
    private func problem(_ destination: UndoRestoreDestination) -> UndoRestoreProblem? {
        switch destination {
        case .eventCalendar(let snapshot): return snapshot.calendarIdentifier == b.calendarIdentifier ? .missing : nil
        case .reminderList(let snapshot): return snapshot.calendarIdentifier == d.calendarIdentifier ? .readOnly : nil
        }
    }

    private var split: UndoBatchPartialRestore.Split {
        UndoBatchPartialRestore.split(members, problem: problem)
    }

    private var refused: UndoRestoreDestinationMissingError {
        UndoRestoreDestinationMissingError(findings: split.findings, total: members.count)
    }

    // MARK: - The split

    func testTheSplitKeepsTheMembersWhoseDestinationIsMissingOrReadOnly() {
        let split = self.split
        XCTAssertEqual(split.restorable.map(\.description), [members[0], members[2], members[4]].map(\.description))
        XCTAssertEqual(split.blocked.map(\.description), [members[1], members[3]].map(\.description))
        XCTAssertEqual(split.findings.map(\.problem), [.missing, .readOnly])
    }

    /// A nested batch is one member: when any of its items is blocked, it is kept whole (no tool
    /// records a nested batch today).
    func testANestedBatchIsKeptWholeWhenAnyOfItsItemsIsBlocked() {
        let nested = UndoOperation.batch([.deleteEvent(snapshot: a), .deleteEvent(snapshot: b)])
        let split = UndoBatchPartialRestore.split([nested, .deleteReminder(snapshot: c)], problem: problem)
        XCTAssertEqual(split.restorable.count, 1)
        XCTAssertEqual(split.blocked.map(\.description), [nested.description])
    }

    // MARK: - The steps

    private final class Steps: @unchecked Sendable {
        var ran: [[String]] = []
        var splits = 0
    }

    private func run(restoreAvailable: Bool, verify: Error? = nil, split: UndoBatchPartialRestore.Split? = nil,
                     runFails: Error? = nil, steps: Steps) async throws -> UndoBatchPartialRestore.Split? {
        let given = split ?? self.split
        let result = try await UndoBatchPartialRestore.run(
            members, restoreAvailable: restoreAvailable,
            verify: { if let verify { throw verify } },
            split: { steps.splits += 1; return given },
            runMembers: { members -> Int in
                steps.ran.append(members.map(\.description))
                if let runFails { throw runFails }
                return members.count
            })
        XCTAssertEqual(result.outcome, steps.ran.last?.count)
        return result.kept
    }

    /// Without the argument the refusal stands, as before #287: nothing runs.
    func testWithoutTheArgumentTheRefusalStands() async throws {
        let steps = Steps()
        do {
            _ = try await run(restoreAvailable: false, verify: refused, steps: steps)
            XCTFail("the refusal must stand")
        } catch is UndoRestoreDestinationMissingError {}
        XCTAssertTrue(steps.ran.isEmpty)
        XCTAssertEqual(steps.splits, 0)
    }

    func testWithTheArgumentOnlyTheRestorableMembersRunAndTheOthersAreKept() async throws {
        let steps = Steps()
        let kept = try await run(restoreAvailable: true, verify: refused, steps: steps)
        XCTAssertEqual(steps.ran, [[members[0], members[2], members[4]].map(\.description)])
        XCTAssertEqual(kept?.blocked.map(\.description), [members[1], members[3]].map(\.description))
    }

    /// Every member blocked: nothing to restore, so the refusal stands, as today.
    func testWhenEveryMemberIsBlockedTheRefusalStands() async throws {
        let steps = Steps()
        let none = UndoBatchPartialRestore.split(members) { _ in .missing }
        do {
            _ = try await run(restoreAvailable: true, verify: refused, split: none, steps: steps)
            XCTFail("the refusal must stand")
        } catch is UndoRestoreDestinationMissingError {}
        XCTAssertTrue(steps.ran.isEmpty)
    }

    /// The split reads the calendars and lists again; if every destination is back by then, the
    /// whole batch runs and nothing is kept.
    func testWhenTheDestinationsAreBackTheWholeBatchRuns() async throws {
        let steps = Steps()
        let back = UndoBatchPartialRestore.split(members) { _ in nil }
        let kept = try await run(restoreAvailable: true, verify: refused, split: back, steps: steps)
        XCTAssertNil(kept)
        XCTAssertEqual(steps.ran, [members.map(\.description)])
    }

    /// The pre-check passes: the batch runs whole and the argument changes nothing.
    func testWhenThePreCheckPassesTheWholeBatchRuns() async throws {
        let steps = Steps()
        let kept = try await run(restoreAvailable: true, steps: steps)
        XCTAssertNil(kept)
        XCTAssertEqual(steps.splits, 0)
        XCTAssertEqual(steps.ran, [members.map(\.description)])
    }

    /// A write that fails part-way on the restorable members keeps #248 A's remainder and the
    /// blocked members too, the blocked ones first (they run last next time).
    func testAPartWayFailureKeepsTheBlockedMembersToo() async throws {
        let steps = Steps()
        let partial = UndoBatchPartiallyUndoneError(remaining: [members[0]], restoredCount: 2, memberError: "eventkit_error_1")
        do {
            _ = try await run(restoreAvailable: true, verify: refused, runFails: partial, steps: steps)
            XCTFail("the part-way failure must surface")
        } catch let stopped as UndoBatchPartialRestoreStoppedError {
            XCTAssertEqual(stopped.remaining.map(\.description), [members[1], members[3], members[0]].map(\.description))
            XCTAssertTrue(stopped.message.contains("2 items whose calendar or list is missing or read-only were not attempted"),
                          stopped.message)
            XCTAssertTrue(stopped.message.contains("eventkit_error_1"), stopped.message)
            XCTAssertFalse(stopped.message.contains("Private calendar title"), stopped.message)
        }
    }

    /// The last restorable member dropped (a permanent error, none left): the entry is not
    /// discarded, as #248 A's text would say, since the blocked members are still in it.
    func testADroppedLastMemberStillKeepsTheBlockedOnes() async throws {
        let steps = Steps()
        let partial = UndoBatchPartiallyUndoneError(remaining: [], restoredCount: 2, memberError: "gone", failing: .dropped)
        do {
            _ = try await run(restoreAvailable: true, verify: refused, runFails: partial, steps: steps)
            XCTFail("the part-way failure must surface")
        } catch let stopped as UndoBatchPartialRestoreStoppedError {
            XCTAssertEqual(stopped.remaining.count, 2)
            XCTAssertFalse(stopped.message.contains("was discarded"), stopped.message)
            XCTAssertTrue(stopped.message.contains("kept with only the 2 items whose calendar or list is missing or read-only"),
                          stopped.message)
        }
    }

    // MARK: - The texts

    func testTheAnswerSaysWhatWasRestoredAndWhatIsKept() {
        let message = UndoBatchPartialRestore.keptMessage(restored: "Undone batch (3 operations)", kept: split)
        XCTAssertTrue(message.hasPrefix("Undone batch (3 operations)"), message)
        XCTAssertTrue(message.contains("2 items of this batch were not restored"), message)
        XCTAssertTrue(message.contains("1 event in a calendar that is not available: 'B'"), message)
        XCTAssertTrue(message.contains("1 reminder in a list that is read-only: 'D'"), message)
        XCTAssertTrue(message.contains("kept with only those 2 items, under the same id"), message)
        XCTAssertTrue(message.contains("discard_id drops only those 2 items"), message)
        XCTAssertFalse(message.contains("Private calendar title"), "no calendar or list title (#37)")
    }

    /// The refusal names the argument when some items could be restored, and not when none can.
    func testTheRefusalNamesTheArgumentOnlyWhenSomeItemsCouldBeRestored() {
        XCTAssertTrue(refused.message.contains("restore_available set to true"), refused.message)
        let all = UndoRestoreDestinationMissingError(findings: UndoBatchPartialRestore.split(members) { _ in .missing }.findings,
                                                     total: members.count)
        XCTAssertFalse(all.message.contains("restore_available"), all.message)
    }
}
