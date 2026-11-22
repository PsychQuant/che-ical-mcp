import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// PR #558 round 1 with #538 merged: what the undo of a whole-series delete that applies none of the
/// recorded exceptions (a recorded slot the recreated series does not generate, `main`'s only such path
/// since fix round 4 removed round 3's two) does with older undo records of the series. It brings the series back from its
/// rules alone, with no occurrence as a separate event, so `DeleteUndoFollow.decision` gives `follow`:
/// the older records move to the recreated series, and none is flagged. (Fix round 5 removed the test of the
/// slot guard's refusal through `handleUndo`, with ruling F.)
final class RulesAloneRestoreFollowHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool { false }
    }

    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func slot(_ week: Int) -> Date { s0.addingTimeInterval(Double(week) * 7 * day) }
    private var window: DateInterval { DateInterval(start: s0.addingTimeInterval(-day), end: slot(3).addingTimeInterval(day)) }

    /// A record at `slot` (its `/RID=` read as an instant) of an occurrence that starts at `start`.
    private func record(slot: Date, start: Date? = nil) -> DetachedOccurrence {
        DetachedOccurrence(slot: slot, snapshot: UndoSnapshotFixtures.event(title: "Edited", startDate: start ?? slot))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else { return "" }
        return text
    }

    /// The two shapes, each a series of four weekly slots whose undo applies none of its exceptions: an
    /// occurrence edited while the series had no time zone, its `/RID=` read as an instant 8 hours off its
    /// slot (a host at `+08:00`, #539), and a stale record of a series moved after the edit (cell N1).
    /// Rewritten in rounds 3 and fix round 4 (its floating and ruling E shapes were removed with their paths).
    private var shapes: [(String, SeriesExceptions)] {
        [("floating edit", SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                            detached: [record(slot: slot(1).addingTimeInterval(8 * hour), start: slot(1))])),
         ("did not match", SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                            detached: [record(slot: slot(1).addingTimeInterval(3 * hour))]))]
    }

    func testANotAppliedRestoreMovesTheOlderRecordsToTheRecreatedSeries() async throws {
        for (name, exceptions) in shapes {
            let store = FakeSeriesExceptionsStore()
            store.seriesSlots = (0...3).map(slot)
            let history = CalendarUndoManager()
            let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0).withExceptions(exceptions)
            await history.record(.createEvent(id: "S", title: "Standup", created: series))
            await history.record(.deleteEvent(id: "S", snapshot: series))
            let server = try await CheICalMCPServer(
                undoManager: history,
                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history))

            let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

            XCTAssertNotEqual(result.isError, true, name)
            let answer = try text(result)
            XCTAssertTrue(answer.contains("Restored from the series rules alone"), "\(name): \(answer)")
            XCTAssertFalse(answer.contains("were not moved"), "\(name): not flagged")
            XCTAssertEqual(store.starts(of: "E1"), (0...3).map(slot), "\(name): every occurrence, no separate event")
            let older = await history.popUndo()
            XCTAssertEqual(older?.operation.eventIdentifiersNamed, ["E1"], "\(name): followed")
            XCTAssertEqual(older?.seriesNotFollowed, false, name)
        }
    }

    /// PR #558 round 2 (H30), rewritten in round 3 and fix round 4: a record applied (its slot a slot of the
    /// recreated series, as on `main`) writes the edited occurrence as a separate event, so #538 flags the older
    /// records of the series instead of moving them, through the production arm (`undoDeletedEvent(_:removedID:)`).
    func testAnAppliedRecordFlagsTheOlderRecords() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let exceptions = SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                          detached: [record(slot: slot(1))])
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0).withExceptions(exceptions)
        await history.record(.createEvent(id: "S", title: "Standup", created: series))
        await history.record(.deleteEvent(id: "S", snapshot: series))
        let server = try await CheICalMCPServer(
            undoManager: history,
            undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history))

        let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        XCTAssertNotEqual(result.isError, true)
        let answer = try text(result)
        XCTAssertTrue(answer.contains("1 occurrence(s) edited on their own came back as separate one-off events"), answer)
        XCTAssertEqual(store.events.filter { $0.title == "Edited" }.map(\.start), [slot(1)], "the edit, once")
        let older = await history.popUndo()
        XCTAssertEqual(older?.seriesNotFollowed, true, "flagged, not moved")
        XCTAssertEqual(older?.operation.eventIdentifiersNamed, ["S"])
    }

    /// The decision itself, for the outcome the not-applied path returns.
    func testTheDecisionForEachNotAppliedOutcomeIsFollow() {
        XCTAssertEqual(DeleteUndoFollow.decision(removedID: "S", newID: "R", isOccurrenceRecord: false,
                                                 outcome: .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true))), .follow("R"))
    }
}
