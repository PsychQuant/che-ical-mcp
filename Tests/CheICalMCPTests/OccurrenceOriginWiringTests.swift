import XCTest
@testable import CheICalMCP

/// #321: where the records take the series identity and the occurrence origin from EventKit, and
/// where the production store keeps and reads the recreated series. An in-memory `EKEvent` has no
/// identifier, so these record sites cannot be run without a device; the wiring is pinned in source
/// (`SourcePins`), and what the pieces do is tested in `OccurrenceOriginTests`,
/// `OccurrenceSlotGuardTests` and `SeriesExceptionsUndoTests`.
final class OccurrenceOriginWiringTests: XCTestCase {
    private func count(_ literal: String, in body: String) -> Int { SourcePins.ranges(of: literal, in: body).count }

    /// `delete_event` / `delete_events_batch`: the occurrence of a series (or an occurrence edited
    /// on its own) carries its origin; the series carries its identity.
    func testTheDeleteSnapshotsCarryTheOriginAndTheSeriesIdentity() throws {
        let source = try SourcePins.source("EventKit/DeleteUndo.swift")
        let initBody = try XCTUnwrap(SourcePins.body(of: "init(series: EKEvent, removed: EKEvent, span: EKSpan = .thisEvent", in: source))
        XCTAssertEqual(count("occurrence = hadRules || isDetached ? removedSnapshot.withOccurrenceOrigin(OccurrenceOrigin.of(removed)) : removedSnapshot", in: initBody), 1)
        XCTAssertEqual(count(".withSeriesIdentity(hadRules ? OccurrenceOrigin.seriesIDs(of: series) : nil)", in: initBody), 1)
    }

    /// `deleteEventSeries` / `deleteEventSeriesBatch` (span all): a series carries its identity; an
    /// occurrence edited on its own, addressed by its own identifier, its origin (PR #318 round 3,
    /// finding 22).
    func testTheSeriesDeleteSnapshotCarriesTheOriginOfAnEditedOccurrence() throws {
        let source = try SourcePins.source("EventKit/DeleteUndo.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "static func recordingSeriesDelete(of event: EKEvent", in: source))
        XCTAssertEqual(count(".withSeriesIdentity(event.hasRecurrenceRules ? OccurrenceOrigin.seriesIDs(of: event) : nil)", in: body), 1)
        XCTAssertEqual(count("return !event.hasRecurrenceRules && event.isDetached ? snapshot.withOccurrenceOrigin(OccurrenceOrigin.of(event)) : snapshot", in: body), 1)
    }

    /// A move that split one occurrence out records its origin, so its undo's slot check (#466 runs
    /// it through the occurrence undo) is the same as an occurrence delete's.
    func testASplitMoveRecordsTheOccurrencesOrigin() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        XCTAssertEqual(count("let snapshot = isSplit ? copied.withOccurrenceOrigin(OccurrenceOrigin.of(subject)) : copied", in: SourcePins.code(source)), 1)
        XCTAssertEqual(count("isDetached: occurrence.isDetached)", in: SourcePins.code(try SourcePins.source("EventKit/DeleteUndo.swift"))), 1,
                       "the origin says whether the occurrence was edited")
    }

    /// The production store notes and reads recreations on the manager's own log, and builds its
    /// slot holders through `OccurrenceSlotGuard.holder` (identifiers and rule slot).
    func testTheProductionStoreKeepsTheRecreationsOnTheManager() throws {
        let wrappers = try SourcePins.source("EventKit/EventKitManager+SeriesExceptions.swift")
        let store = try XCTUnwrap(SourcePins.body(of: "var seriesExceptionsStore: EventKitSeriesExceptionsStore", in: wrappers))
        XCTAssertEqual(count("noteRecreation: { self.seriesRecreations.note($0, recreatedAs: $1) },", in: store), 1)
        XCTAssertEqual(count("recreations: { self.seriesRecreations.recreations(of: $0) })", in: store), 1)
        let adapter = try SourcePins.source("EventKit/SeriesExceptionsStoreSource.swift")
        let holders = try XCTUnwrap(SourcePins.body(of: "func slotHolders(at slot: Date, length: TimeInterval, in calendar: EKCalendar)", in: adapter))
        XCTAssertEqual(count("holders.append(OccurrenceSlotGuard.holder(eventIdentifier: event.eventIdentifier,", in: holders), 1)
        XCTAssertEqual(count("refreshIfNeeded()", in: holders), 1, "the series an earlier undo recreated is seen")
    }

    /// The whole-series undo notes the recreation only after its exceptions were restored (a failed
    /// restore deletes the series again, so nothing is noted), and only for a series.
    func testTheRecreationIsNotedAfterTheRestore() throws {
        let source = SourcePins.code(try SourcePins.source("EventKit/SeriesExceptionsUndo.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "static func undoDeleteEvent<", in: source))
        let restore = try XCTUnwrap(body.range(of: "outcome = try restore(exceptions, of: event, in: store)"))
        let note = try XCTUnwrap(body.range(of: "store.noteRecreation(of: recorded, as: store.identifiers(of: event))"))
        XCTAssertLessThan(restore.lowerBound, note.lowerBound)
        XCTAssertEqual(count("if snapshot.restoresFromRules, let recorded = snapshot.seriesIdentity {", in: body), 1)
    }
}
