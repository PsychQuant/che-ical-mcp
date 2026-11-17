import XCTest
@testable import CheICalMCP

/// #538: the undo history side of "records follow an item the undo of its delete recreated": the
/// event rewrite leaves delete records alone, the reminder rewrite and its kinds, and the flag a
/// series that was not followed leaves on its entries. On `CalendarUndoManager` itself.
final class DeleteUndoFollowHistoryTests: XCTestCase {
    private func event(_ title: String) -> EventSnapshot { UndoSnapshotFixtures.event(title: title) }
    private func reminder(_ title: String) -> ReminderSnapshot { UndoSnapshotFixtures.reminder(title: title) }

    /// The event identifiers the top-to-bottom entries of a stack name (`eventIdentifiersNamed`),
    /// and, for delete records, the identifier they hold.
    private func ids(_ operation: UndoOperation) -> [String] {
        switch operation {
        case .deleteEvent(let id, _), .deleteReminder(let id, _): return ["removed:" + id]
        case .createReminder(let id, _, _), .updateReminder(let id, _, _): return ["reminder:" + id]
        case .completeReminder(let id, _, _, _, _, _, _): return ["reminder:" + id]
        case .completeRecurringReminder(let before, _, _): return ["reminder:" + before.id]
        case .batch(let members): return members.flatMap(ids)
        default: return operation.eventIdentifiersNamed
        }
    }

    private func undoIDs(_ history: CalendarUndoManager) async -> [[String]] {
        var stack: [[String]] = []
        while let record = await history.popUndo() { stack.append(ids(record.operation)) }
        return stack
    }

    // MARK: - event records

    /// A create and an update record of the event follow; the delete record that holds the same
    /// identifier does not, on the undo stack and, after its undo, on the redo stack.
    func testOlderRecordsFollowAndTheDeleteRecordKeepsTheRemovedIdentifier() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "A", title: "Review", created: event("Review")))
        await history.record(.updateEvent(id: "A", oldSnapshot: event("Review"), saved: event("Review 2")))
        await history.record(.createEvent(id: "other", title: "Other", created: event("Other")))
        await history.record(.deleteEvent(id: "A", snapshot: event("Review 2")))
        await history.record(.batch([.deleteEvent(id: "A", snapshot: event("Review 2"))]))

        await history.replaceEventIdentifier("A", with: "B")

        let undo = await undoIDs(history)
        XCTAssertEqual(undo, [["removed:A"], ["removed:A"], ["other"], ["B"], ["B"]])
    }

    func testADeleteRecordOnTheRedoStackKeepsTheRemovedIdentifier() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "A", title: "Review", created: event("Review")))
        await history.record(.deleteEvent(id: "A", snapshot: event("Review")))
        let awaited1 = try await history.beginUndo()
        let undone = try XCTUnwrap(awaited1)
        await history.finishHistoryOperation(undone)

        await history.replaceEventIdentifier("A", with: "B")

        let awaited2 = await history.popRedo()
        let redo = try XCTUnwrap(awaited2)
        XCTAssertEqual(ids(redo.operation), ["removed:A"], "the redo record names the removed event")
        _ = await history.popUndo()
        let awaited3 = await history.popUndo()
        let value1 = ids(try XCTUnwrap(awaited3).operation)
        XCTAssertEqual(value1, ["B"], "the create record follows")
    }

    // MARK: - reminder records

    /// spec-example: undo-history-discard / the reminder rewrite and the event rewrite stay apart
    func testTheReminderRewriteAndTheEventRewriteStayApart() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "X", title: "Event", created: event("Event")))
        await history.record(.createReminder(id: "X", title: "Rent", created: reminder("Rent")))
        await history.record(.deleteReminder(id: "X", snapshot: reminder("Rent")))

        await history.replaceReminderIdentifier("X", with: "Y")

        let value2 = await undoIDs(history)
        XCTAssertEqual(value2, [["removed:X"], ["reminder:Y"], ["X"]])
    }

    /// The other direction: an event rewrite leaves a reminder record that names the same string.
    func testTheEventRewriteLeavesReminderRecords() async {
        let history = CalendarUndoManager()
        await history.record(.createReminder(id: "X", title: "Rent", created: reminder("Rent")))
        await history.record(.createEvent(id: "X", title: "Event", created: event("Event")))

        await history.replaceEventIdentifier("X", with: "Y")

        let value3 = await undoIDs(history)
        XCTAssertEqual(value3, [["Y"], ["reminder:X"]])
    }

    /// Each of the four reminder record kinds follows, a batch member too; a recurring completion
    /// keeps every other field of its occurrence snapshot.
    func testEveryReminderRecordKindFollows() async throws {
        let before = ReminderCompletionSnapshot(id: "X", title: "Daily", calendarID: "c", sourceID: "s", isCompleted: false,
                                                hasRecurrence: true, due: nil, rules: [], completionDate: nil)
        let history = CalendarUndoManager()
        await history.record(.createReminder(id: "X", title: "Rent", created: reminder("Rent")))
        await history.record(.updateReminder(id: "X", oldSnapshot: reminder("Rent"), saved: reminder("Rent 2")))
        await history.record(.completeReminder(id: "X", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                                               title: "Rent 2", redoCompletionDate: nil, wasRecurring: false))
        await history.record(.completeRecurringReminder(before: before, requestedCompleted: true, redoCompletionDate: nil))
        await history.record(.batch([.createReminder(id: "X", title: "Rent", created: reminder("Rent")),
                                     .deleteReminder(id: "X", snapshot: reminder("Rent"))]))

        await history.replaceReminderIdentifier("X", with: "Y")

        let awaited4 = await history.popUndo()
        let top = try XCTUnwrap(awaited4)
        XCTAssertEqual(ids(top.operation), ["reminder:Y", "removed:X"])
        let awaited5 = await history.popUndo()
        let recurring = try XCTUnwrap(awaited5)
        guard case .completeRecurringReminder(let followed, true, nil) = recurring.operation else { return XCTFail("\(recurring.operation)") }
        XCTAssertEqual(followed, before.replacingIdentifier("Y"))
        XCTAssertEqual(followed.id, "Y")
        XCTAssertEqual([followed.title, followed.calendarID, followed.sourceID], ["Daily", "c", "s"])
        XCTAssertTrue(followed.hasRecurrence)
        let value4 = await undoIDs(history)
        XCTAssertEqual(value4, [["reminder:Y"], ["reminder:Y"], ["reminder:Y"]])
    }

    func testTheReminderRewriteReachesTheRedoStack() async throws {
        let history = CalendarUndoManager()
        await history.record(.updateReminder(id: "X", oldSnapshot: reminder("Rent"), saved: reminder("Rent 2")))
        let awaited6 = try await history.beginUndo()
        let record = try XCTUnwrap(awaited6)
        await history.finishHistoryOperation(record)

        await history.replaceReminderIdentifier("X", with: "Y")

        let awaited7 = await history.popRedo()
        let value5 = ids(try XCTUnwrap(awaited7).operation)
        XCTAssertEqual(value5, ["reminder:Y"])
    }

    // MARK: - the flag

    private func flags(_ history: CalendarUndoManager, _ ids: [UUID]) async -> [Bool?] {
        var result: [Bool?] = []
        for id in ids { result.append(await history.isSeriesNotFollowed(id)) }
        return result
    }

    private func topID(_ history: CalendarUndoManager) async throws -> UUID {
        let snapshot = await history.historySnapshot()
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(snapshot.entries.first).id))
    }

    /// spec-example: undo-history-discard / what is flagged
    ///
    /// The create, whole-series move and #263 update entries that name the series are flagged and
    /// counted, on both stacks. Not flagged: the marker of an update that touched the series (#538
    /// fix 1, R3: its undo is refused and the entry discarded before any lookup, so the flagged text
    /// never comes and `discard_id` is not needed), a delete record that holds the same string, and
    /// the entries of other events.
    func testMarkingFlagsTheEntriesThatNameTheSeries() async throws {
        let history = CalendarUndoManager()
        var ids: [UUID] = []
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup"))); ids.append(try await topID(history))
        await history.record(.moveEvent(id: "S", fromCalendarIdentifier: "c1", toCalendarIdentifier: "c2", title: "Standup", isSeries: true))
        ids.append(try await topID(history))
        await history.record(.createEvent(id: "other", title: "Other", created: event("Other"))); ids.append(try await topID(history))
        await history.record(.updateRecurringEvent(id: "S", title: "Standup", kind: .series)); ids.append(try await topID(history))
        await history.record(.updateSeries(seriesUpdate("S"))); ids.append(try await topID(history))
        await history.record(.deleteEvent(id: "S", snapshot: event("Standup"))); ids.append(try await topID(history))
        let awaited8 = try await history.beginUndo()
        let undone = try XCTUnwrap(awaited8)
        await history.finishHistoryOperation(undone)

        let count = await history.markSeriesNotFollowed("S")

        XCTAssertEqual(count, 3, "the create, the move and the #263 update")
        let flagged = await flags(history, ids)
        XCTAssertEqual(flagged, [true, true, false, false, true, false],
                       "the marker is not flagged; the delete record on the redo stack is not flagged")
        let value6 = await history.markSeriesNotFollowed("")
        XCTAssertEqual(value6, 0)
    }

    func testAnEntryOnTheRedoStackIsFlagged() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup")))
        let id = try await topID(history)
        let awaited9 = try await history.beginUndo()
        let record = try XCTUnwrap(awaited9)
        await history.restoreFailedUndo(record)
        _ = await history.popUndo()

        let value7 = await history.markSeriesNotFollowed("S")
        XCTAssertEqual(value7, 1)
        let value8 = await history.isSeriesNotFollowed(id)
        XCTAssertEqual(value8, true)
    }

    /// The flag is part of the entry: kept by narrowing, a failed undo put back, the move to the
    /// redo stack and back, and a rewrite of another identifier; flagged twice it is flagged once
    /// and counted again.
    func testTheFlagStaysWithItsEntry() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup")))
        let id = try await topID(history)
        let value9 = await history.markSeriesNotFollowed("S")
        XCTAssertEqual(value9, 1)

        let awaited10 = try await history.beginUndo()
        let begun = try XCTUnwrap(awaited10)
        XCTAssertTrue(begun.seriesNotFollowed, "the entry undo begins carries it")
        XCTAssertTrue(begun.narrowed(to: begun.operation).seriesNotFollowed, "narrowing keeps it")
        await history.restoreFailedUndo(begun)
        let value10 = await history.isSeriesNotFollowed(id)
        XCTAssertEqual(value10, true, "a failed undo puts it back flagged")

        _ = await history.popUndo()
        let value11 = await history.isSeriesNotFollowed(id)
        XCTAssertEqual(value11, true, "on the redo stack")
        _ = await history.popRedo()
        let value12 = await history.isSeriesNotFollowed(id)
        XCTAssertEqual(value12, true, "back on the undo stack")

        await history.replaceEventIdentifier("T", with: "U")
        let value13 = await history.isSeriesNotFollowed(id)
        XCTAssertEqual(value13, true, "a rewrite of another identifier keeps it")
        let value14 = await history.markSeriesNotFollowed("S")
        XCTAssertEqual(value14, 1, "flagged again, counted again")
        let value15 = await history.isSeriesNotFollowed(id)
        XCTAssertEqual(value15, true)
    }

    /// A new record is not flagged, and a discarded entry takes its flag with it.
    func testTheFlagGoesWithItsEntry() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: event("Older")))
        let older = try await topID(history)
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup")))
        let flagged = try await topID(history)
        let value16 = await history.markSeriesNotFollowed("S")
        XCTAssertEqual(value16, 1)

        _ = try await history.discardUndo(expectedID: flagged)

        let value17 = await history.isSeriesNotFollowed(flagged)
        XCTAssertNil(value17, "gone with its entry")
        let value18 = await history.isSeriesNotFollowed(older)
        XCTAssertEqual(value18, false)
    }

    /// `eventIdentifiersNamed` lists exactly what `replacingEventIdentifier` rewrites, per kind.
    func testTheNamedIdentifiersAreTheOnesTheEventRewriteMoves() {
        let exceptions = SeriesExceptions(window: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86_400),
                                          keptSlots: [], detached: [])
        let series = SeriesUpdateRecord(id: "S", externalIdentifier: "X-S", old: event("t"), saved: event("t"),
                                        fields: ["title"], before: exceptions, after: exceptions)
        let kinds: [UndoOperation] = [
            .createEvent(id: "S", title: "t", created: event("t")),
            .updateEvent(id: "S", oldSnapshot: event("t"), saved: event("t")),
            .updateRecurringEvent(id: "S", title: "t", kind: .series),
            .updateSeries(series),
            .moveEvent(id: "S", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "t", isSeries: false),
            .moveByCopy(original: event("t"), isSplit: false, notCarriedOver: [], copyID: "S", copy: event("t")),
        ]
        for operation in kinds {
            XCTAssertEqual(operation.eventIdentifiersNamed, ["S"], "\(operation)")
            XCTAssertEqual(operation.replacingEventIdentifier("S", with: "T").eventIdentifiersNamed, ["T"], "\(operation)")
        }
        let none: [UndoOperation] = [
            .deleteEvent(id: "S", snapshot: event("t")), .deleteOccurrence(snapshot: event("t"), notCarriedOver: []),
            .deleteFollowingOccurrences(title: "t"), .createReminder(id: "S", title: "t", created: reminder("t")),
            .deleteReminder(id: "S", snapshot: reminder("t")), .calendarOperation(kind: .created, title: "t"),
        ]
        for operation in none { XCTAssertEqual(operation.eventIdentifiersNamed, [], "\(operation)") }
    }

    private func seriesUpdate(_ id: String) -> SeriesUpdateRecord {
        let exceptions = SeriesExceptions(window: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86_400),
                                          keptSlots: [], detached: [])
        return SeriesUpdateRecord(id: id, externalIdentifier: "X-" + id, old: event("Standup"), saved: event("Standup 2"),
                                  fields: ["title"], before: exceptions, after: exceptions)
    }

    /// The marker and a batch carry no not-followed title, so neither is flagged; every kind that
    /// is flagged has one (#538 fix 1, R3, F33).
    func testOnlyKindsWithANotFollowedTitleAreFlagged() async throws {
        let history = CalendarUndoManager()
        await history.record(.batch([.createEvent(id: "S", title: "Standup", created: event("Standup"))]))
        let batch = try await topID(history)
        await history.record(.updateRecurringEvent(id: "S", title: "Standup", kind: .occurrence))
        let marker = try await topID(history)

        let count = await history.markSeriesNotFollowed("S")

        XCTAssertEqual(count, 0)
        let flagged = await flags(history, [batch, marker])
        XCTAssertEqual(flagged, [false, false])
        XCTAssertNil(UndoOperation.updateRecurringEvent(id: "S", title: "Standup", kind: .series).notFollowedTitle)
        XCTAssertNil(UndoOperation.batch([.createEvent(id: "S", title: "Standup", created: event("Standup"))]).notFollowedTitle)
    }

    /// spec-example: undo-history-discard / the rewrite after a recreate leaves the #263 record
    ///
    /// #538 fix 1 (R4): a #263 whole-series update record names the series as it was, with its
    /// occurrences, and its undo compares the series' external identifier, which a recreated series
    /// does not have; so the rewrite after the undo of a delete leaves it, on both stacks, while the
    /// create records follow. The rewrite for the same event under a new identifier (#435, #484)
    /// still moves it.
    func testTheRewriteAfterARecreateLeavesTheWholeSeriesUpdateRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup")))
        await history.record(.updateSeries(seriesUpdate("S")))
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup")))
        for _ in 0..<2 {
            let begun = try await history.beginUndo()
            await history.finishHistoryOperation(try XCTUnwrap(begun))
        }

        await history.replaceEventIdentifier("S", with: "T", change: .recreated)

        let first = await history.popRedo()
        XCTAssertEqual(ids(try XCTUnwrap(first).operation), ["S"], "redo stack: the #263 record stays")
        let second = await history.popRedo()
        XCTAssertEqual(ids(try XCTUnwrap(second).operation), ["T"], "redo stack: the create record follows")
        let undo = await undoIDs(history)
        XCTAssertEqual(undo, [["T"], ["S"], ["T"]], "undo stack, after both came back")

        let sameEvent = UndoOperation.updateSeries(seriesUpdate("S")).replacingEventIdentifier("S", with: "T", change: .sameEvent)
        XCTAssertEqual(sameEvent.eventIdentifiersNamed, ["T"], "#435 and #484 still move it")
        XCTAssertEqual(UndoOperation.updateSeries(seriesUpdate("S")).replacingEventIdentifier("S", with: "T").eventIdentifiersNamed, ["T"],
                       "the default is the same event")
        let recreated = UndoOperation.batch([.updateSeries(seriesUpdate("S")), .createEvent(id: "S", title: "t", created: event("t"))])
            .replacingEventIdentifier("S", with: "T", change: .recreated)
        XCTAssertEqual(recreated.eventIdentifiersNamed, ["S", "T"], "inside a batch too")
    }

    /// The same on the undo stack, in its order, with another kind of each.
    func testOnTheUndoStackOnlyTheWholeSeriesUpdateRecordStays() async {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "S", title: "Standup", created: event("Standup")))
        await history.record(.updateSeries(seriesUpdate("S")))
        await history.record(.moveEvent(id: "S", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "Standup", isSeries: true))
        await history.record(.updateRecurringEvent(id: "S", title: "Standup", kind: .series))

        await history.replaceEventIdentifier("S", with: "T", change: .recreated)

        let undo = await undoIDs(history)
        XCTAssertEqual(undo, [["T"], ["T"], ["S"], ["T"]])
    }
}
