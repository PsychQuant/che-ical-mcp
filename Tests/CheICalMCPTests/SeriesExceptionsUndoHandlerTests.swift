import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #322: `undo` of a delete record, through the handler and the real `EventKitManager.executeUndo`
/// arms, with the delete-undo exceptions layer on an in-memory store
/// (`forTesting(probe:seriesExceptionsStore:)`). Before #322 these arms ran only on device; the
/// existing handler tests reached them with an unauthorized store, so only refusals ran.
final class SeriesExceptionsUndoHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool { false }
    }

    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func slot(_ week: Int) -> Date { s0.addingTimeInterval(Double(week) * 7 * day) }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return ""
        }
        return text
    }

    private func undo(_ history: CalendarUndoManager, on store: FakeSeriesExceptionsStore) async throws -> CallTool.Result {
        let server = try await CheICalMCPServer(
            undoManager: history,
            undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store))
        return await server.handleToolCallForTesting(name: "undo", arguments: [:])
    }

    /// A series recorded with its exceptions: weeks 0 and 1 kept, week 2 edited on its own, week 3
    /// deleted on its own.
    private func recordedSeriesDelete() -> UndoOperation {
        let edited = UndoSnapshotFixtures.event(title: "Standup moved", startDate: slot(2).addingTimeInterval(1800))
        let exceptions = SeriesExceptions(window: DateInterval(start: s0.addingTimeInterval(-day), end: slot(3).addingTimeInterval(day)),
                                          keptSlots: [slot(0), slot(1)], detached: [DetachedOccurrence(slot: slot(2), snapshot: edited)])
        return .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0)
            .withExceptions(exceptions))
    }

    private func history(with operation: UndoOperation) async -> CalendarUndoManager {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(operation)
        return history
    }

    func testUndoOfASeriesDeleteRestoresItsExceptionsAndUsesUpTheRecord() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = await history(with: recordedSeriesDelete())

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Undone: restored event 'Standup' (new ID: E1)"), message)
        XCTAssertTrue(message.contains("1 occurrence(s) deleted on their own earlier stayed deleted, 1 occurrence(s) edited on their own came back"), message)
        XCTAssertEqual(store.starts(of: "E1"), [slot(0), slot(1)])
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Created event: Older"], "the record is used up")
    }

    func testAFailedOneOffKeepsTheRecordAndLeavesNothing() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        store.failingSaveTitles = ["Standup moved"]
        let history = await history(with: recordedSeriesDelete())
        let before = await history.historySnapshot()

        let result = try await undo(history, on: store)

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Undo could not recreate the occurrence edited on its own"), message)
        XCTAssertEqual(store.events.count, 0)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id), "kept on top, same id, for a retry or discard_id")
    }

    func testAFailedCompensatingDeleteDiscardsTheRecord() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        store.failingSaveTitles = ["Standup moved"]
        store.seriesRemovalFails = true
        let history = await history(with: recordedSeriesDelete())

        let result = try await undo(history, on: store)

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("this undo entry is discarded because a retry would create a second series"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Created event: Older"], "discarded; the older record is on top")
    }

    /// #321: the record ties the occurrence to series S at its rule slot.
    private func origin(_ week: Int) -> OccurrenceOrigin {
        OccurrenceOrigin(series: .init(eventIdentifier: "S", externalIdentifier: "X-S"), slot: slot(week))
    }

    func testUndoOfAnOccurrenceDeleteWhoseSlotTheSeriesHoldsWritesNothing() async throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: slot(1)).withOccurrenceOrigin(origin(1))
        store.addSeries(id: "S", calendar: occurrence.calendarIdentifier, title: "Standup", slots: [slot(0), slot(1)])
        let history = await history(with: .deleteOccurrence(snapshot: occurrence, notCarriedOver: []))

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("is already restored by its series, so nothing was written"), message)
        XCTAssertEqual(store.log, ["calendar", "holders"])
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Created event: Older"], "the record is used up")
    }

    func testUndoOfAnOccurrenceDeleteWithAFreeSlotWritesAOneOff() async throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: slot(1)).withOccurrenceOrigin(origin(1))
        let history = await history(with: .deleteOccurrence(snapshot: occurrence, notCarriedOver: []))

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("restored the deleted occurrence of 'Standup' as a one-off event (new ID: E1)"), message)
        XCTAssertEqual(store.log, ["calendar", "holders", "save Standup"])
    }

    /// #322 (PR #400 verify round 1): the handler tests above run the override branch. The
    /// production branch of each undo arm, and the capture, run `SeriesExceptionsUndo` on the
    /// manager's own store (`seriesExceptionsStore`, built on `eventStore`); this pins that wiring,
    /// which only a device run executes.
    func testTheProductionBranchesRunOnTheManagersOwnStore() throws {
        let source = try SourcePins.source("EventKit/EventKitManager+SeriesExceptions.swift")
        for (declaration, call) in [
            // #466 (PR #474 round 2): both take the restore kind, so a move by copy's source is refused
            // in a move's words; the delete arms take the defaults.
            ("func undoDeletedEvent(_ snapshot: EventSnapshot, kind: EventRestoreKind = .recreateDeleted)", "undoDeletedEvent(snapshot, kind: kind, on: "),
            ("func undoDeletedOccurrence(_ snapshot: EventSnapshot, notCarriedOver: [String],",
             "undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver, kind: kind, on: "),
        ] {
            let body = try XCTUnwrap(SourcePins.body(of: declaration, in: source), declaration)
            XCTAssertEqual(SourcePins.ranges(of: "if let store = seriesExceptionsStoreOverride {", in: body).count, 1, declaration)
            XCTAssertEqual(SourcePins.ranges(of: "return try await " + call + "store)", in: body).count, 1, declaration)
            XCTAssertEqual(SourcePins.ranges(of: "return try await " + call + "seriesExceptionsStore)", in: body).count, 1, declaration)
        }
        let capture = try XCTUnwrap(SourcePins.body(of: "func captureSeriesExceptions(of series: EKEvent)", in: source))
        XCTAssertEqual(SourcePins.ranges(of: "SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore)", in: capture).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "seriesExceptionsStoreOverride", in: capture).count, 0, "the capture never reads the override")
        let store = try XCTUnwrap(SourcePins.body(of: "var seriesExceptionsStore: EventKitSeriesExceptionsStore", in: source))
        XCTAssertEqual(SourcePins.ranges(of: "EventKitSeriesExceptionsStore(eventStore: eventStore,", in: store).count, 1)
    }

    // MARK: - #269 (PR #389) through the moved arms

    /// The recorded calendar is missing: the whole-series undo is refused at the calendar read,
    /// before anything is written, with #269's message for a deleted event, and the record kept.
    func testAWholeSeriesUndoIntoAMissingCalendarIsRefusedAndKept() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let operation = recordedSeriesDelete()
        guard case .deleteEvent(let snapshot) = operation else { return XCTFail("record") }
        store.missingCalendars = [snapshot.calendarIdentifier]
        let history = await history(with: operation)
        let before = await history.historySnapshot()

        let result = try await undo(history, on: store)

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot undo the deletion of an event (event 'Standup'): the calendar it was in when it was deleted"), message)
        XCTAssertEqual(store.log, ["calendar"], "refused at the calendar read; nothing saved")
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id), "kept on top, same id")
    }

    /// The same for an occurrence, with its own wording, before the slot check.
    func testAnOccurrenceUndoIntoAMissingCalendarIsRefusedBeforeTheSlotCheck() async throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: slot(1))
        store.missingCalendars = [occurrence.calendarIdentifier]
        let history = await history(with: .deleteOccurrence(snapshot: occurrence, notCarriedOver: []))

        let result = try await undo(history, on: store)

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot undo the deletion of an occurrence of an event (event 'Standup')"), message)
        XCTAssertEqual(store.log, ["calendar"])
    }
}
