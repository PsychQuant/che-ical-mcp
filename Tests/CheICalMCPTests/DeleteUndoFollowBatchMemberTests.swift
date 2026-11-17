import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// #538, moved here by #559 (G14, G18) from `DeleteUndoFollowHandlerTests`: the members of a batch
/// undo through `EventKitManager.undoBatchMember`, the arm a batch undo calls, and through
/// `UndoBatchExecution.run`, on an in-memory store that gives every recreated event a new identifier
/// (`E1`, `E2`, …). No `handle*` method is reached: a batch undo through the handler reads the real
/// calendars before its first write (#248 B), which this store cannot give, so these are
/// manager-level tests, as `EventKitManagerForTestingTests` is; `UndoBatchWiringTests` pins how
/// `undoBatch` builds its answer from the same outcome.
final class DeleteUndoFollowBatchMemberTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool { false }
    }

    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func slot(_ week: Int) -> Date { s0.addingTimeInterval(Double(week) * 7 * day) }

    /// The identifier each entry names, top first (`eventIdentifiersNamed`; delete records hold one too).
    private func named(_ history: CalendarUndoManager) async -> [String] {
        var result: [String] = []
        while let record = await history.popUndo() {
            if case .deleteEvent(let id, _) = record.operation { result.append("removed:" + id); continue }
            result.append(record.operation.eventIdentifiersNamed.joined(separator: ","))
        }
        return result
    }

    private func seriesWithAnEditedOccurrence() -> EventSnapshot {
        let edited = UndoSnapshotFixtures.event(title: "Standup moved", startDate: slot(2).addingTimeInterval(1800))
        let exceptions = SeriesExceptions(window: DateInterval(start: s0.addingTimeInterval(-day), end: slot(3).addingTimeInterval(day)),
                                          keptSlots: [slot(0), slot(1)], detached: [DetachedOccurrence(slot: slot(2), snapshot: edited)])
        return UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0).withExceptions(exceptions)
    }

    /// spec scenario: a batch follows member by member. A batch undo reads the real calendars
    /// before its first write (#248 B), which this store cannot give, so each member runs through
    /// `undoBatchMember`, the arm the batch calls. The test checks the end state: each create record
    /// names the event its own member recreated (#559, G18: renamed from "…RightAfterItsOwnWrite",
    /// which the end state does not show; `testABatchThatStopsPartWay…` shows that only the members written follow).
    func testBatchMembersFollowTheirOwnRecreatedEvents() async throws {
        let store = FakeSeriesExceptionsStore()
        let history = CalendarUndoManager()
        let a = UndoSnapshotFixtures.event(title: "A", startDate: s0)
        let b = UndoSnapshotFixtures.event(title: "B", startDate: slot(1))
        await history.record(.createEvent(id: "a", title: "A", created: a))
        await history.record(.createEvent(id: "b", title: "B", created: b))
        let manager = EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history)

        _ = try await manager.undoBatchMember(.deleteEvent(id: "b", snapshot: b))
        let afterFirst = await history.historySnapshot().entries.count
        _ = try await manager.undoBatchMember(.deleteEvent(id: "a", snapshot: a))

        XCTAssertEqual(afterFirst, 2)
        let value1 = await named(history)
        XCTAssertEqual(value1, ["E1", "E2"], "b became E1 after the first member, a became E2 after the second")
    }

    /// R1: a batch member whose series flagged older records carries the count of separate events as
    /// data, since the batch answer reads no member text; without an older entry it carries none.
    func testABatchMemberCarriesTheCountWhenItFlagged() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "S", title: "Standup", created: seriesWithAnEditedOccurrence()))
        let manager = EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history)

        let flagged = try await manager.undoBatchMember(.deleteEvent(id: "S", snapshot: seriesWithAnEditedOccurrence()))
        let otherStore = FakeSeriesExceptionsStore()
        otherStore.seriesSlots = (0...3).map(slot)
        let other = EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: otherStore, undoHistory: CalendarUndoManager())
        let alone = try await other.undoBatchMember(.deleteEvent(id: "R", snapshot: seriesWithAnEditedOccurrence()))
        let oneOff = try await other.undoBatchMember(.deleteEvent(id: "a", snapshot: UndoSnapshotFixtures.event(title: "A", startDate: slot(5))))

        XCTAssertEqual(flagged.notFollowed, [1])
        XCTAssertEqual(alone.notFollowed, [], "no older entry names it: nothing flagged, nothing said")
        XCTAssertEqual(oneOff.notFollowed, [])
    }

    /// R1: through the batch runner with the member arm the batch uses, the message built from the
    /// runner's outcome as `undoBatch` builds it ends with the batch sentence (#559, G14: the batch's
    /// own answer is not checked here, so the name says what is); a batch whose members flagged nothing does not. (A batch
    /// undo through the handler reads the real calendars first, #248 B, which this store cannot give;
    /// `UndoBatchWiringTests` pins that `undoBatch` passes the count to `batchUndoneMessage`.)
    func testTheMessageBuiltFromTheRunnerOutcomeSaysItForAFlaggedMember() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let a = UndoSnapshotFixtures.event(title: "A", startDate: slot(1).addingTimeInterval(3600))
        await history.record(.createEvent(id: "S", title: "Standup", created: seriesWithAnEditedOccurrence()))
        await history.record(.createEvent(id: "a", title: "A", created: a))
        let manager = EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history)

        let outcome = try await UndoBatchExecution.run(
            [.deleteEvent(id: "a", snapshot: a), .deleteEvent(id: "S", snapshot: seriesWithAnEditedOccurrence())], verb: .undo,
            check: { _ in }, restore: { try await manager.undoBatchMember($0) }, describe: { "\($0)" })
        let answer = UndoOperation.batchUndoneMessage(count: outcome.texts.count, events: outcome.events, differing: outcome.differing,
                                                      notFollowed: outcome.notFollowed)

        XCTAssertEqual(outcome.notFollowed, [1])
        XCTAssertTrue(answer.hasSuffix(" Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because 1 of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id."), answer)
        let value = await named(history)
        XCTAssertEqual(value.count, 2)
        XCTAssertTrue(value[0].hasPrefix("E") && value[0] != "E1", "the one-off followed its recreated event: \(value)")
        XCTAssertEqual(value[1], "S", "the series' create record kept its identifier")

        let plainHistory = CalendarUndoManager()
        let plainManager = EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: FakeSeriesExceptionsStore(),
                                                      undoHistory: plainHistory)
        let plain = try await UndoBatchExecution.run(
            [.deleteEvent(id: "a", snapshot: a), .deleteEvent(id: "b", snapshot: UndoSnapshotFixtures.event(title: "B", startDate: s0))],
            verb: .undo, check: { _ in }, restore: { try await plainManager.undoBatchMember($0) }, describe: { "\($0)" })
        XCTAssertEqual(plain.notFollowed, [])
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: plain.texts.count, events: plain.events, differing: plain.differing,
                                                        notFollowed: plain.notFollowed), "Undone batch (2 operations)")
    }

    /// R1 and F19: a batch undo that stops part-way. The series restored first flagged its older
    /// entries, and the part-way text says so; the one-off restored before the failure followed; the
    /// member that failed is kept under its own identifier, and its create record still names it.
    func testABatchThatStopsPartWaySaysItAndFollowsOnlyWhatWasWritten() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        store.failingSaveTitles = ["Broken"]
        let history = CalendarUndoManager()
        let a = UndoSnapshotFixtures.event(title: "A", startDate: slot(1).addingTimeInterval(3600))
        let broken = UndoSnapshotFixtures.event(title: "Broken", startDate: slot(1).addingTimeInterval(7200))
        await history.record(.createEvent(id: "b", title: "Broken", created: broken))
        await history.record(.createEvent(id: "S", title: "Standup", created: seriesWithAnEditedOccurrence()))
        await history.record(.createEvent(id: "a", title: "A", created: a))
        let manager = EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history)
        let members: [UndoOperation] = [.deleteEvent(id: "b", snapshot: broken), .deleteEvent(id: "a", snapshot: a),
                                        .deleteEvent(id: "S", snapshot: seriesWithAnEditedOccurrence())]

        do {
            _ = try await UndoBatchExecution.run(members, verb: .undo, check: { _ in },
                                                 restore: { try await manager.undoBatchMember($0) }, describe: { _ in "member error" })
            XCTFail("the third member fails")
        } catch let partial as UndoBatchPartiallyUndoneError {
            XCTAssertEqual(partial.restoredCount, 2)
            XCTAssertEqual(partial.restoredNotFollowed, [1])
            XCTAssertTrue(partial.message.contains(" Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because 1 of its occurrences"), partial.message)
            XCTAssertEqual(partial.message.components(separatedBy: "were not moved").count, 2, "said once")
            guard case .deleteEvent(let keptID, _)? = partial.remaining.first, partial.remaining.count == 1 else {
                return XCTFail("\(partial.remaining)")
            }
            XCTAssertEqual(keptID, "b", "the member not restored keeps its removed identifier")
        }
        let value = await named(history)
        XCTAssertEqual(value.count, 3)
        XCTAssertTrue(value[0].hasPrefix("E") && value[0] != "E1", "a followed its write: \(value)")
        XCTAssertEqual(Array(value.dropFirst()), ["S", "b"], "the series was flagged, b was not written")
    }
}
