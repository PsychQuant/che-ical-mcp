import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// PR #558 round 1 with #538 merged: what the undo of a whole-series delete that applies none of the
/// recorded exceptions (the record cannot be placed, rulings B, C, D, or a placed record ends before it
/// starts, ruling E) does with older undo records of the series. It brings the series back from its
/// rules alone, with no occurrence as a separate event, so `DeleteUndoFollow.decision` gives `follow`:
/// the older records move to the recreated series, and none is flagged. Then the slot guard's refusal
/// (`OccurrenceSlotWallClockRefusal`) through `handleUndo`, for an entry #538 flagged and for one it did
/// not: the caller gets the refusal's own text, and the entry is kept.
final class RulesAloneRestoreFollowHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool { false }
    }

    private actor RefusingExecutor: UndoExecutionSource {
        let refusal: OccurrenceSlotWallClockRefusal
        init(_ refusal: OccurrenceSlotWallClockRefusal) { self.refusal = refusal }
        func executeUndo(_ operation: UndoOperation) async throws -> String { throw refusal }
        func executeRedo(_ operation: UndoOperation) async throws -> String { "" }
    }

    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func slot(_ week: Int) -> Date { s0.addingTimeInterval(Double(week) * 7 * day) }
    private var window: DateInterval { DateInterval(start: s0.addingTimeInterval(-day), end: slot(3).addingTimeInterval(day)) }

    private func record(_ readings: SlotReadings, end: Date? = nil) -> DetachedOccurrence {
        let start = readings.wallClock ?? readings.instant
        return DetachedOccurrence(slot: readings.instant, snapshot: UndoSnapshotFixtures.event(title: "Edited", startDate: start, endDate: end),
                                  readings: readings)
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else { return "" }
        return text
    }

    /// The four shapes, each a series of four weekly slots whose undo applies none of its exceptions.
    private var shapes: [(String, SeriesExceptions)] {
        [("B: on a kept slot", SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                                detached: [record(SlotReadings(instant: slot(1).addingTimeInterval(8 * hour), wallClock: slot(0)))])),
         ("C: outside every window", SeriesExceptions(window: DateInterval(start: window.start, end: slot(2).addingTimeInterval(-hour)),
                                                      keptSlots: [slot(0), slot(1)],
                                                      detached: [record(SlotReadings(instant: slot(2).addingTimeInterval(-9 * hour), wallClock: slot(2)))])),
         ("D: two on one slot", SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                                 detached: [record(SlotReadings(instant: slot(1).addingTimeInterval(8 * hour), wallClock: slot(1))),
                                                            record(SlotReadings(instant: slot(1), wallClock: slot(1).addingTimeInterval(-8 * hour)))])),
         ("E: ends before it starts", SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                                       detached: [record(SlotReadings(instant: slot(1)), end: slot(1).addingTimeInterval(-30 * 60))])),
         // PR #558 round 2 (ruling I): the first slot not a plain occurrence at the capture.
         ("I: first slot not plain", SeriesExceptions(window: window, keptSlots: [slot(2), slot(3)],
                                                      detached: [record(SlotReadings(instant: slot(1).addingTimeInterval(8 * hour), wallClock: slot(1)))]))]
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

    /// PR #558 round 2 (H30): a floating series whose record of two readings is placed and applied writes the
    /// edited occurrence as a separate event, so #538 flags the older records of the series instead of moving
    /// them, through the production arm (`undoDeletedEvent(_:removedID:)`), as for a series with a time zone.
    func testAPlacedFloatingRecordFlagsTheOlderRecords() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let exceptions = SeriesExceptions(window: window, keptSlots: [slot(0), slot(2), slot(3)],
                                          detached: [record(SlotReadings(instant: slot(1).addingTimeInterval(8 * hour), wallClock: slot(1)))])
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

    /// The decision itself, for the outcome each not-applied path returns.
    func testTheDecisionForEachNotAppliedOutcomeIsFollow() {
        for outcome in [SeriesExceptionsRestorer.Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true),
                        SeriesExceptionsRestorer.Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true, endsBeforeStart: true),
                        SeriesExceptionsRestorer.Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true, firstSlotNotPlain: true)] {
            XCTAssertEqual(DeleteUndoFollow.decision(removedID: "S", newID: "R", isOccurrenceRecord: false,
                                                     outcome: .seriesWithExceptions(outcome)), .follow("R"))
        }
    }

    /// The refusal reaches the caller unchanged for a flagged entry (its catch is for a not-found only)
    /// and for a plain one, and the entry stays on top.
    func testTheGuardsRefusalReachesTheCallerForAFlaggedAndAPlainEntry() async throws {
        let refusal = OccurrenceSlotWallClockRefusal(title: "Third", kind: .undoMoveByCopy)
        for flag in [true, false] {
            let history = CalendarUndoManager()
            let original = UndoSnapshotFixtures.event(title: "Third")
            await history.record(.moveByCopy(original: original, isSplit: true, notCarriedOver: [], copyID: "COPY", copy: original))
            if flag {
                let marked = await history.markSeriesNotFollowed("COPY")
                XCTAssertEqual(marked, 1)
            }
            let before = await history.historySnapshot().entries.first?.id
            let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: RefusingExecutor(refusal))

            let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

            XCTAssertEqual(result.isError, true)
            let raw = try text(result)
            XCTAssertEqual(raw.hasPrefix("Error: ") ? String(raw.dropFirst(7)) : raw, refusal.message, "flagged \(flag)")
            let after = await history.historySnapshot().entries.first?.id
            XCTAssertEqual(after, before, "kept on top, flagged \(flag)")
            let kept = await history.popUndo()
            XCTAssertEqual(kept?.seriesNotFollowed, flag)
        }
    }
}
