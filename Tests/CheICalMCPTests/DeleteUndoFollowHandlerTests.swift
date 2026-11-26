import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #538: `undo` of a delete record through the handler and the real `EventKitManager.executeUndo`
/// arms, on an in-memory store that gives every recreated event a new identifier (`E1`, `E2`, …)
/// and with the history the arms move records in (`forTesting(probe:seriesExceptionsStore:undoHistory:)`).
/// Then the answer of an entry that was flagged instead of moved, through a source that throws the
/// not-found every lookup of a recreated series meets.
final class DeleteUndoFollowHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool { false }
    }

    /// Every undo answers not found, as the lookup of a series that no longer exists does.
    private actor MissingExecutor: UndoExecutionSource {
        func executeUndo(_ operation: UndoOperation) async throws -> String {
            throw UndoTargetMissingError(verb: .undo, kind: .event, title: operation.notFollowedTitle ?? "?", hasIdentifier: true)
        }
        func executeRedo(_ operation: UndoOperation) async throws -> String { "" }
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

    /// The `message` of a success, or the text of an error without its `Error: ` prefix.
    private func message(_ result: CallTool.Result) throws -> String {
        let raw = try text(result)
        if result.isError == true { return raw.hasPrefix("Error: ") ? String(raw.dropFirst(7)) : raw }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return try XCTUnwrap(object["message"] as? String)
    }

    private func undo(_ history: CalendarUndoManager, on store: FakeSeriesExceptionsStore) async throws -> CallTool.Result {
        let server = try await TestServer.make(
            undoManager: history,
            undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe(), seriesExceptionsStore: store, undoHistory: history))
        return await server.handleToolCallForTesting(name: "undo", arguments: [:])
    }

    private func undo(_ history: CalendarUndoManager, source: any UndoExecutionSource,
                      arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        let server = try await TestServer.make(undoManager: history, undoExecutionSource: source)
        return await server.handleToolCallForTesting(name: "undo", arguments: arguments)
    }

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

    // MARK: - follow

    /// spec scenario: a one-off event's create record follows its delete's undo.
    func testTheCreateRecordOfAOneOffFollowsTheRecreatedEvent() async throws {
        let store = FakeSeriesExceptionsStore()
        let history = CalendarUndoManager()
        let review = UndoSnapshotFixtures.event(title: "Review", startDate: s0)
        await history.record(.createEvent(id: "A", title: "Review", created: review))
        await history.record(.updateEvent(id: "A", oldSnapshot: review, saved: review))
        await history.record(.createEvent(id: "other", title: "Other", created: review))
        await history.record(.deleteEvent(id: "A", snapshot: review))

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(try text(result).contains("Undone: restored event 'Review' (new ID: E1)"), true)
        let value1 = await named(history)
        XCTAssertEqual(value1, ["other", "E1", "E1"])
    }

    /// A series recreated from its rules (no exceptions recorded) is followed too.
    func testASeriesRecreatedFromItsRulesIsFollowed() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0)
        await history.record(.createEvent(id: "S", title: "Standup", created: series))
        await history.record(.deleteEvent(id: "S", snapshot: series))

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        XCTAssertFalse(try text(result).contains("were not moved"))
        let value2 = await named(history)
        XCTAssertEqual(value2, ["E1"])
    }

    /// spec scenario: a series whose edited occurrence came back as a separate event is not followed:
    /// its create record keeps its identifier, is flagged, and the answer says so once.
    func testASeriesWithASeparateEventIsFlaggedAndSaysSo() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let series = seriesWithAnEditedOccurrence()
        await history.record(.createEvent(id: "S", title: "Standup", created: series))
        let snapshot = await history.historySnapshot()
        let create = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(snapshot.entries.first).id))
        await history.record(.deleteEvent(id: "S", snapshot: series))

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        let answer = try message(result)
        XCTAssertTrue(answer.hasSuffix(". " + DeleteUndoFollow.notFollowedSentence(oneOffs: 1)), answer)
        XCTAssertEqual(answer.components(separatedBy: "were not moved").count, 2, "said once")
        let value3 = await history.isSeriesNotFollowed(create)
        XCTAssertEqual(value3, true)
        let value4 = await named(history)
        XCTAssertEqual(value4, ["S"], "not moved")
    }

    /// The same series without an older entry that names it: nothing to flag, no sentence.
    func testWithoutAnOlderEntryTheSentenceIsLeftOut() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        await history.record(.deleteEvent(id: "S", snapshot: seriesWithAnEditedOccurrence()))

        let answer = try message(try await undo(history, on: store))

        XCTAssertTrue(answer.hasPrefix("Undone: restored event 'Standup' (new ID: E1)"), answer)
        XCTAssertFalse(answer.contains("were not moved"), answer)
    }

    /// spec scenario: an occurrence's delete is not followed. The series' create record keeps the series.
    func testAnOccurrenceDeleteIsNotFollowed() async throws {
        let store = FakeSeriesExceptionsStore()
        let history = CalendarUndoManager()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: slot(1))
            .withOccurrenceOrigin(OccurrenceOrigin(series: .init(eventIdentifier: "S", externalIdentifier: "X-S"), slot: slot(1)))
        await history.record(.createEvent(id: "S", title: "Standup", created: occurrence))
        await history.record(.deleteOccurrence(snapshot: occurrence, notCarriedOver: []))

        let result = try await undo(history, on: store)

        XCTAssertTrue(try text(result).contains("(new ID: E1)"))
        let value5 = await named(history)
        XCTAssertEqual(value5, ["S"])
    }

    /// The rule-less record of one occurrence (a series delete through an edited occurrence's own
    /// identifier) is not followed either.
    func testTheRuleLessRecordOfAnOccurrenceIsNotFollowed() async throws {
        let store = FakeSeriesExceptionsStore()
        let history = CalendarUndoManager()
        let detached = UndoSnapshotFixtures.event(title: "Standup moved", startDate: slot(1))
            .withOccurrenceOrigin(OccurrenceOrigin(series: .init(eventIdentifier: "S", externalIdentifier: "X-S"), slot: slot(1)))
        await history.record(.createEvent(id: "S/RID=1", title: "Standup moved", created: detached))
        await history.record(.deleteEvent(id: "S/RID=1", snapshot: detached))

        _ = try await undo(history, on: store)

        let value6 = await named(history)
        XCTAssertEqual(value6, ["S/RID=1"])
    }

    // MARK: - the flagged entry

    private func flaggedHistory() async throws -> (CalendarUndoManager, older: String, flagged: String) {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "O", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        let first = await history.historySnapshot()
        let older = try XCTUnwrap(first.entries.first).id
        await history.record(.createEvent(id: "S", title: "Stand'up", created: UndoSnapshotFixtures.event(title: "Stand'up")))
        let second = await history.historySnapshot()
        let flagged = try XCTUnwrap(second.entries.first).id
        let value8 = await history.markSeriesNotFollowed("S")
        XCTAssertEqual(value8, 1)
        return (history, older, flagged)
    }

    /// spec scenario: the undo of a flagged entry that is not found answers the not-followed text,
    /// writes nothing and keeps the entry on top with its id.
    func testAFlaggedEntryAnswersTheNotFollowedText() async throws {
        let (history, _, flagged) = try await flaggedHistory()

        let result = try await undo(history, source: MissingExecutor())

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(try message(result), UndoTargetMissingError.seriesNotFollowed(title: "Stand'up").message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.first?.id, flagged, "kept on top, same id")
        XCTAssertEqual(after.redoCount, 0)
    }

    /// spec-example: undo-history-discard / the flag goes with its entry
    func testAfterTheFlaggedEntryIsDiscardedTheGenericNotFoundIsBack() async throws {
        let (history, older, flagged) = try await flaggedHistory()
        _ = try await undo(history, source: MissingExecutor())
        _ = try await undo(history, source: MissingExecutor(), arguments: ["discard_id": .string(flagged)])

        let result = try await undo(history, source: MissingExecutor())

        XCTAssertEqual(result.isError, true)
        let answer = try message(result)
        XCTAssertEqual(answer, UndoTargetMissingError(verb: .undo, kind: .event, title: "Older", hasIdentifier: true).message)
        XCTAssertFalse(answer.contains("recreated by an undo"), answer)
        let value9 = await history.historySnapshot().entries.first?.id
        XCTAssertEqual(value9, older)
    }

    /// An entry that was never flagged answers the generic not-found, as before #538.
    func testAnEntryWithoutTheFlagAnswersTheGenericNotFound() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "S", title: "Standup", created: UndoSnapshotFixtures.event(title: "Standup")))

        let answer = try message(try await undo(history, source: MissingExecutor()))

        XCTAssertEqual(answer, UndoTargetMissingError(verb: .undo, kind: .event, title: "Standup", hasIdentifier: true).message)
    }

    /// What the two texts hold: the entry's title and a count, nothing else of the record (calendar,
    /// account, notes, location, identifiers set to marker strings), and nothing on stderr.
    func testTheTwoTextsHoldOnlyTheTitleAndACount() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let series = seriesWithAnEditedOccurrence()
        await history.record(.createEvent(id: "MARKER-ID-1", title: "Standup", created: series))
        await history.record(.deleteEvent(id: "MARKER-ID-1", snapshot: series))

        let (sentence, sentenceErr) = try await withCapturedStderrAsync { try self.message(try await self.undo(history, on: store)) }
        let refused = UndoTargetMissingError.seriesNotFollowed(title: "Standup").message
        let (answered, answeredErr) = try await withCapturedStderrAsync { try self.message(try await self.undo(history, source: MissingExecutor())) }

        XCTAssertEqual(answered, refused)
        let added = String(sentence.suffix(DeleteUndoFollow.notFollowedSentence(oneOffs: 1).count))
        XCTAssertEqual(added, DeleteUndoFollow.notFollowedSentence(oneOffs: 1))
        for marker in ["MARKER-ID-1", "E1", series.calendarIdentifier, series.calendarTitle] where !marker.isEmpty {
            XCTAssertFalse(added.contains(marker), marker)
            XCTAssertFalse(refused.contains(marker), marker)
        }
        XCTAssertEqual(refused.components(separatedBy: "'Standup'").count, 2, "the title once")
        XCTAssertEqual(sentenceErr, "")
        XCTAssertEqual(answeredErr, "")
    }

    // MARK: - #538 fix 1

    /// The text the flagged refusal answers for an entry whose recorded title is `title`, written out.
    private func refusal(_ title: String) -> String {
        "Cannot undo: the recurring event '\(title)' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names no longer exists. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."
    }

    /// F18: each kind that can be flagged shows its own recorded title, through the production path
    /// (`handleUndo` and the real builder): an update's title before it, a #263 update's old title.
    /// The other titles of the record are not shown. A move by copy is not flagged (#559).
    func testEachFlaggedKindShowsItsOwnRecordedTitle() async throws {
        let exceptions = SeriesExceptions(window: DateInterval(start: s0, duration: day), keptSlots: [], detached: [])
        let cases: [(UndoOperation, String)] = [
            (.createEvent(id: "S", title: "Created", created: UndoSnapshotFixtures.event(title: "Snapshot")), "Created"),
            (.updateEvent(id: "S", oldSnapshot: UndoSnapshotFixtures.event(title: "Before"),
                          saved: UndoSnapshotFixtures.event(title: "After")), "Before"),
            (.moveEvent(id: "S", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "Moved", isSeries: true), "Moved"),
            (.updateSeries(SeriesUpdateRecord(id: "S", externalIdentifier: "X-S", old: UndoSnapshotFixtures.event(title: "Series before"),
                                              saved: UndoSnapshotFixtures.event(title: "Series after"), fields: ["title"],
                                              before: exceptions, after: exceptions)), "Series before"),
            // A move by copy is not flagged (#559): its undo restores the original first and then reports
            // a copy it does not find as not found (where the original's slot is already held it writes
            // nothing and does not look the copy up).
        ]
        for (operation, title) in cases {
            let history = CalendarUndoManager()
            await history.record(operation)
            let flagged = await history.markSeriesNotFollowed("S")
            XCTAssertEqual(flagged, 1, title)

            let answer = try message(try await undo(history, source: MissingExecutor()))

            XCTAssertEqual(answer, refusal(title), title)
        }
    }

    /// R4 (#263): the undo of a series' delete moves the create record to the recreated series but
    /// leaves a whole-series update record on the removed identifier, so its undo answers not found
    /// (that undo reads the store, which this test cannot give; the record's identifier is what decides).
    func testAWholeSeriesUpdateRecordIsNotMovedByTheDeleteUndo() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(slot)
        let history = CalendarUndoManager()
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0)
        let exceptions = SeriesExceptions(window: DateInterval(start: s0, duration: day), keptSlots: [], detached: [])
        await history.record(.createEvent(id: "S", title: "Standup", created: series))
        await history.record(.updateSeries(SeriesUpdateRecord(id: "S", externalIdentifier: "X-S", old: series, saved: series,
                                                              fields: ["title"], before: exceptions, after: exceptions)))
        await history.record(.deleteEvent(id: "S", snapshot: series))

        let result = try await undo(history, on: store)

        XCTAssertNotEqual(result.isError, true)
        let value = await named(history)
        XCTAssertEqual(value, ["S", "E1"], "the #263 update record stays, the create record follows")
    }
}
