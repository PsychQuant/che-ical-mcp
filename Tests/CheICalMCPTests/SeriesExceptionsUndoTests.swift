import EventKit
import XCTest
@testable import CheICalMCP

/// #322: the delete-undo exceptions layer (`SeriesExceptionsUndo`, #285) run against an in-memory
/// store (`FakeSeriesExceptionsStore`): what the capture records, what the two undo arms write and
/// in which order, and what they answer when a write fails. Before #322 this code talked to
/// EventKit directly and was checked on device only.
final class SeriesExceptionsUndoTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var s1: Date { s0.addingTimeInterval(7 * day) }
    private var s2: Date { s0.addingTimeInterval(14 * day) }
    private var s3: Date { s0.addingTimeInterval(21 * day) }

    private func slotLog(_ date: Date) -> String { "remove \(date.timeIntervalSince1970)" }

    // MARK: - capture

    /// A series of four weekly occurrences: the third deleted on its own, the second edited on its
    /// own and moved by half an hour, and another series in the same calendar. The capture keeps
    /// the slots that exist unedited, records the edited one by its rule slot, ignores the other
    /// series, and lists the window and a year each side as three queries. The edited occurrence
    /// reads back as iCloud showed (#311): its identifiers carry `/RID=<seconds since 2001>` of its
    /// slot, and its `occurrenceDate` has drifted to the moved start, so only the `/RID=` reading
    /// of `SeriesExceptionsPlanner.ruleSlot` gives the slot.
    func testTheCaptureRecordsKeptSlotsAndEditedOccurrencesOfThisSeriesOnly() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: [s0, s1, s3])
        let rid = "/RID=\(Int(s1.timeIntervalSinceReferenceDate))"
        occurrences[1].id = "S" + rid
        occurrences[1].external = "X-S" + rid
        occurrences[1].detached = true
        occurrences[1].start = s1.addingTimeInterval(1800)
        occurrences[1].occurrenceDate = occurrences[1].start
        store.addSeries(id: "T", calendar: "C", title: "Other", slots: [s0, s2])
        store.seriesEnd = .endsAt(s3)

        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: s0))

        XCTAssertEqual(exceptions.keptSlots, [s0, s3])
        XCTAssertEqual(exceptions.detached.map(\.slot), [s1])
        XCTAssertEqual(exceptions.window, DateInterval(start: s0.addingTimeInterval(-day), end: s3.addingTimeInterval(day)),
                       "a series begun at the delete: from a day before its first occurrence to a day after its end (#319)")
        XCTAssertEqual(store.log, ["list", "list", "list"], "the window and a year on each side, one query each")
    }

    /// Nothing is listed for a series without a calendar or without an identifier: the record then
    /// says its exceptions were not checked (nil), not that it had none.
    func testTheCaptureIsNilWithoutACalendarOrAnIdentifier() {
        let store = FakeSeriesExceptionsStore()
        let noCalendar = FakeSeriesExceptionsStore.Event(id: "S", title: "Standup", start: s0, hasRules: true)
        XCTAssertNil(SeriesExceptionsUndo.capture(of: noCalendar, in: store))
        let noID = FakeSeriesExceptionsStore.Event(id: "", calendar: "C", title: "Standup", start: s0, hasRules: true)
        XCTAssertNil(SeriesExceptionsUndo.capture(of: noID, in: store))
        XCTAssertEqual(store.log, [], "nothing listed")
    }

    // MARK: - undo of a whole-series delete

    /// The series recorded with s0 and s1 kept, s2 edited on its own (moved), s3 deleted on its own:
    /// undo saves the series from its rules, lists its occurrences over the recorded window, removes
    /// s2 and s3, then recreates the edited one as a one-off. The text counts one of each.
    private func recordedSeries() -> (snapshot: EventSnapshot, edited: EventSnapshot) {
        let edited = UndoSnapshotFixtures.event(title: "Standup moved", startDate: s2.addingTimeInterval(1800))
        let exceptions = SeriesExceptions(window: DateInterval(start: s0.addingTimeInterval(-day), end: s3.addingTimeInterval(day)),
                                          keptSlots: [s0, s1], detached: [DetachedOccurrence(slot: s2, snapshot: edited)])
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0).withExceptions(exceptions)
        return (series, edited)
    }

    func testTheWholeSeriesUndoRestoresTheRecordedExceptions() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let (series, edited) = recordedSeries()

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 1)), "#323: what it did, as data")
        XCTAssertEqual(store.log, ["save series Standup", "list", slotLog(s2), slotLog(s3), "save Standup moved"])
        XCTAssertEqual(store.starts(of: "E1"), [s0, s1], "the series keeps the slots that existed unedited")
        XCTAssertEqual(store.events.filter { $0.title == "Standup moved" }.map(\.start), [edited.startDate],
                       "the edited occurrence is back as a one-off at its edited start")
        XCTAssertTrue(text.hasPrefix("Undone: restored event 'Standup' (new ID: E1)"), text)
        XCTAssertTrue(text.contains("1 occurrence(s) deleted on their own earlier stayed deleted, 1 occurrence(s) edited on their own came back"), text)
        XCTAssertEqual(store.refreshMarks, 1)
    }

    /// #323: an event that is not a series has nothing to disclose and returns no outcome.
    func testAOneOffEventUndoReturnsNoOutcome() throws {
        let store = FakeSeriesExceptionsStore()
        let event = UndoSnapshotFixtures.event(title: "Review", startDate: s0)
        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(event, calendar: event.calendarIdentifier, in: store)
        XCTAssertNil(outcome)
        XCTAssertEqual(text, "Undone: restored event 'Review' (new ID: E1)")
    }

    /// No recorded exceptions (the capture was nil): the series comes back from its rules alone,
    /// nothing is listed or removed, and the text says so.
    func testAWholeSeriesUndoWithoutRecordedExceptionsRestoresFromTheRulesAlone() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0)

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .seriesFromRules)
        XCTAssertEqual(store.log, ["save series Standup"])
        XCTAssertEqual(store.starts(of: "E1"), [s0, s1, s2, s3])
        XCTAssertEqual(text, "Undone: restored event 'Standup' (new ID: E1). " + UndoOperation.seriesRulesRestoreNote)
    }

    /// The edited occurrence cannot be saved: the series is deleted again, nothing is left, and the
    /// error keeps the record (`.restore`, so the user can retry or give it up).
    func testAOneOffThatCannotBeSavedDeletesTheSeriesAgainAndKeepsTheRecord() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]

        do {
            let series = recordedSeries().snapshot
            _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Undo could not recreate the occurrence edited on its own on "), error.localizedDescription)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        }
        XCTAssertEqual(store.log.suffix(2), ["save failed Standup moved", "remove series"])
        XCTAssertEqual(store.events.count, 0, "nothing of the recreated series or the one-off is left")
    }

    /// #288: the cleanup asks whether the one-off that failed to save was stored. A lookup that
    /// failed does not say it was not, so the event is reported as maybe left, not as nothing done.
    func testAFailedLookupDuringTheCleanupIsReportedAsMaybeLeft() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]
        store.isStoredFails = true

        do {
            let series = recordedSeries().snapshot
            _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
            XCTFail("must throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("nothing was restored"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("may"), error.localizedDescription)
        }
    }

    // MARK: - #398: the failure's code reaches the text

    /// An EventKit error whose description names a calendar (remote-set text, #37).
    private func eventKitError(_ code: Int) -> NSError {
        NSError(domain: EKErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "The calendar 'Therapy notes' refused the change"])
    }

    /// The edited occurrence's save fails with an EventKit error: the text names its code, so a
    /// failure that recurs on every retry can be told from a passing one, and never its description.
    func testAOneOffSaveFailureNamesItsEventKitCodeAndNotItsDescription() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]
        store.saveFailure = eventKitError(3)

        do {
            let series = recordedSeries().snapshot
            _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
            XCTFail("must throw")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.hasPrefix("Undo could not recreate the occurrence edited on its own on "), text)
            XCTAssertTrue(text.contains("(eventkit_error_3)"), text)
            XCTAssertTrue(text.contains("if it keeps failing with the same code"), text)
            XCTAssertFalse(text.contains("Therapy notes"), text)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        }
        XCTAssertEqual(store.events.count, 0, "what is written does not change: nothing is left")
    }

    /// A failure that is not an EventKit error gets the sanitizer's generic code.
    func testAOneOffSaveFailureThatIsNotAnEventKitErrorNamesTheGenericCode() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]

        do {
            let series = recordedSeries().snapshot
            _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("(error_unknown)"), error.localizedDescription)
        }
    }

    /// Removing a surplus occurrence fails: the series is deleted again, the record is kept, and
    /// the text names the removal's code, not its description.
    func testASurplusRemovalFailureNamesItsEventKitCode() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingRemovalSlots = [s3]
        store.removalFailure = eventKitError(1)

        do {
            let series = recordedSeries().snapshot
            _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
            XCTFail("must throw")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.hasPrefix("Undo could not remove the occurrence on "), text)
            XCTAssertTrue(text.contains("(eventkit_error_1)"), text)
            XCTAssertTrue(text.contains("if it keeps failing with the same code, discard_id gives up this undo"), text)
            XCTAssertFalse(text.contains("Therapy notes"), text)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        }
        XCTAssertEqual(store.log.suffix(3), [slotLog(s2), "remove failed \(s3.timeIntervalSince1970)", "remove series"])
        XCTAssertEqual(store.events.count, 0)
    }

    /// Every text of a rolled-back restore that has a failure names its code (#398).
    func testEveryRolledBackFailureTextNamesItsCode() {
        let cases: [SeriesExceptionsRestoreError] = [
            .removeFailed(s1, code: "eventkit_error_7"), .oneOffFailed(s1, code: "eventkit_error_7"),
            .strayOneOffs(s1, code: "eventkit_error_7"), .oneOffMaybeLeft(s1, code: "eventkit_error_7"),
        ]
        for error in cases {
            let text = SeriesExceptionsUndo.restoreFailure(error).localizedDescription
            XCTAssertTrue(text.contains("(eventkit_error_7)"), "\(error): \(text)")
            XCTAssertEqual(UndoFailureDisposition.of(SeriesExceptionsUndo.restoreFailure(error)), .restore, "\(error)")
        }
    }

    /// The compensating delete fails too: permanent, the record is discarded (a retry would create
    /// a second series).
    func testAFailedCompensatingDeleteIsPermanent() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        store.failingSaveTitles = ["Standup moved"]
        store.seriesRemovalFails = true

        do {
            let series = recordedSeries().snapshot
            _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is UnrecoverableUndoError, "\(error)")
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
            XCTAssertTrue(error.localizedDescription.contains("the series exists with 2 occurrence(s) removed"), error.localizedDescription)
        }
    }

    // MARK: - undo of an occurrence delete

    /// The calendar already holds a recurring event with the occurrence's title at its start (the
    /// series came back from its rules): nothing is written.
    func testAnOccurrenceWhoseSlotTheSeriesHoldsIsNotWrittenAgain() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1).withOccurrenceOrigin(origin(s1))
        store.addSeries(id: "S", calendar: occurrence.calendarIdentifier, title: "Standup", slots: [s0, s1])

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: [], calendar: occurrence.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceAlreadyHeld)

        XCTAssertEqual(text, UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup"))
        XCTAssertEqual(store.log, ["holders"], "nothing saved")
    }

    /// The slot is free (only a one-off with that title is there): the occurrence comes back as a
    /// one-off event.
    func testAnOccurrenceWhoseSlotIsFreeComesBackAsAOneOff() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1).withOccurrenceOrigin(origin(s1))
        store.add(.init(id: "O", calendar: occurrence.calendarIdentifier, title: "Standup", start: s1))

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: ["absolute_alarms"], calendar: occurrence.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceOneOff(notCarriedOver: ["absolute_alarms"]))

        XCTAssertEqual(store.log, ["holders", "save Standup"])
        XCTAssertEqual(text, UndoOperation.occurrenceRestoredMessage(title: "Standup", newID: "E1", notCarriedOver: ["absolute_alarms"]))
        XCTAssertEqual(store.refreshMarks, 1)
    }

    // MARK: - #321: the slot is held by the recorded series or the one undo recreated from it

    private let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "X-S")
    private func origin(_ slot: Date) -> OccurrenceOrigin { OccurrenceOrigin(series: seriesIDs, slot: slot) }
    private func editedOrigin(_ slot: Date) -> OccurrenceOrigin { OccurrenceOrigin(series: seriesIDs, slot: slot, edited: true) }

    /// The record of the whole-series delete of S, rules only (no exceptions recorded).
    private var seriesS: EventSnapshot {
        UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: s0).withSeriesIdentity(seriesIDs)
    }

    /// An unrelated series with the same title holds the occurrence's time: before #321 that held
    /// the slot, so the undo answered success and wrote nothing. The occurrence comes back now.
    func testAnOccurrenceBesideAnotherSeriesWithItsTitleComesBackAsAOneOff() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1).withOccurrenceOrigin(origin(s1))
        store.addSeries(id: "T", calendar: occurrence.calendarIdentifier, title: "Standup", slots: [s0, s1])

        let (_, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: [], calendar: occurrence.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceOneOff(notCarriedOver: []))
        XCTAssertEqual(store.log, ["holders", "save Standup"])
    }

    /// The series was deleted whole and its undo recreated it from its rules (new identifiers), then
    /// the earlier delete of one occurrence is undone. That occurrence had been retitled and moved
    /// before its delete: it is matched by its series and rule slot, not its edited title and start,
    /// so the recreated series holds it and nothing is written.
    func testTheSeriesAWholeSeriesUndoRecreatedHoldsAnEditedOccurrencesSlot() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let series = seriesS
        _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
        let edited = UndoSnapshotFixtures.event(title: "Standup (moved)", startDate: s1.addingTimeInterval(1800))
            .withOccurrenceOrigin(origin(s1))

        // Same calendar as the series (each fixture gets its own).
        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(edited, notCarriedOver: [], calendar: series.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceAlreadyHeld)
        XCTAssertEqual(text, UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup (moved)"))
        XCTAssertEqual(store.log.filter { $0.hasPrefix("save") }, ["save series Standup"], "only the series was saved")
    }

    /// The undecidable side (#321 default): a record that does not say which series the occurrence
    /// belonged to writes the one-off, and says that its series may also hold that time.
    func testARecordWithoutAnOriginWritesTheOneOffAndSaysTheSlotWasNotChecked() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1)
        store.addSeries(id: "S", calendar: occurrence.calendarIdentifier, title: "Standup", slots: [s0, s1])

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: [], calendar: occurrence.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceOneOffSlotUnchecked(notCarriedOver: []), "round 2: the batch text can say it too")
        XCTAssertEqual(store.log, ["save Standup"], "no slot check without a series to check against")
        XCTAssertTrue(text.contains(UndoOperation.occurrenceSlotUncheckedNote), text)
    }

    /// PR #318 round 3, finding 22: a series delete addressed by an occurrence edited on its own
    /// (its own identifier) is recorded as a rule-less `.deleteEvent`. After the series' undo
    /// recreated it from its rules, that record's undo used to write a one-off at the slot the rules
    /// already brought back. It is guarded as an occurrence record is.
    func testTheDeleteRecordOfAnEditedOccurrenceIsGuardedToo() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let series = seriesS
        _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
        XCTAssertEqual(store.notedRecreations.map(\.recorded), [seriesIDs])
        XCTAssertEqual(store.notedRecreations.map(\.recreated), [.init(eventIdentifier: "E1", externalIdentifier: "X-E1")])
        // Round 2: as production records it, an occurrence edited on its own (`edited`).
        let detached = UndoSnapshotFixtures.event(title: "Standup moved", startDate: s1.addingTimeInterval(1800))
            .withOccurrenceOrigin(editedOrigin(s1))

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(detached, calendar: series.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .editedOccurrenceAlreadyHeld)
        XCTAssertEqual(text, UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup moved", edited: true))
        XCTAssertEqual(store.log.filter { $0.hasPrefix("save") }, ["save series Standup"])
    }

    /// The same record with its series not restored: the slot is free, so the one-off is written.
    func testTheDeleteRecordOfAnEditedOccurrenceIsWrittenWhenTheSlotIsFree() throws {
        let store = FakeSeriesExceptionsStore()
        let detached = UndoSnapshotFixtures.event(title: "Standup moved", startDate: s1.addingTimeInterval(1800))
            .withOccurrenceOrigin(editedOrigin(s1))

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(detached, calendar: detached.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceOneOff(notCarriedOver: []), "round 2: an occurrence's record says what it did, for a batch")
        XCTAssertEqual(text, UndoOperation.eventRestoredMessage(snapshot: detached, newID: "E1"))
        XCTAssertEqual(store.log, ["holders", "save Standup moved"])
    }

    // MARK: - #319: the capture of a long-running series lists around the delete

    /// An open-ended weekly series begun ten years before the delete, with an occurrence near the
    /// delete deleted on its own and another edited on its own. Before #319 the window was the
    /// series' first four years, so only the first occurrence was recorded and the undo brought the
    /// deleted one back. Now the window starts three years before the delete.
    func testTheCaptureOfAnOldSeriesListsAroundTheDelete() throws {
        let now = s0
        let first = now.addingTimeInterval(-3650 * day)
        let near = [-14.0, -7, 7, 14].map { now.addingTimeInterval($0 * day) }
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: [first] + near)
        let rid = "/RID=\(Int(near[2].timeIntervalSinceReferenceDate))"
        occurrences[3].id = "S" + rid
        occurrences[3].external = "X-S" + rid
        occurrences[3].detached = true
        occurrences[3].start = near[2].addingTimeInterval(1800)

        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now))

        XCTAssertEqual(exceptions.window.start, now.addingTimeInterval(-1094 * day), "three years before the delete (PR #494 round 1)")
        XCTAssertEqual(exceptions.keptSlots, [near[0], near[1], near[3]], "the slot at the delete is absent: deleted on its own")
        XCTAssertEqual(exceptions.detached.map(\.slot), [near[2]])
        XCTAssertTrue(exceptions.seriesStartsBeforeWindow)
        XCTAssertTrue(exceptions.seriesContinuesAfterWindow)
    }

    /// #319 (cost): only the series' own occurrences are turned into snapshots; another series in
    /// the same calendar is listed but not snapshotted.
    func testTheCaptureSnapshotsOnlyTheSeriesOwnOccurrences() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: [s0, s1])
        store.addSeries(id: "T", calendar: "C", title: "Other", slots: [s0, s1, s2])
        store.add(.init(id: "O", calendar: "C", title: "One-off", start: s2))

        // Round 2: `now` injected, so the test does not depend on the wall clock.
        _ = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: s0))

        XCTAssertEqual(store.observedCount, 2)
    }

    // MARK: - PR #494 round 1: count rules

    /// A weekly series of 10 that ended years before the delete, one occurrence deleted on its own.
    /// Placed as open-ended, its window lay after the series and the capture was nil (the undo then
    /// brought the deleted occurrence back). Placed by its count, the window holds it.
    func testTheCaptureOfACountSeriesThatEndedLongAgoRecordsItsExceptions() throws {
        let now = s0
        let first = now.addingTimeInterval(-3000 * day)
        let slots = (0..<10).map { first.addingTimeInterval(Double($0) * 7 * day) }
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots.enumerated().filter { $0.offset != 4 }.map(\.element))
        store.seriesEnd = .endsBy(first.addingTimeInterval(70 * day))

        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now))

        XCTAssertEqual(exceptions.keptSlots.count, 9)
        XCTAssertFalse(exceptions.keptSlots.contains(slots[4]))
        XCTAssertFalse(exceptions.seriesContinuesAfterWindow)
        XCTAssertFalse(exceptions.seriesMayContinueAfterWindow)
    }

    // MARK: - PR #494 round 1: the texts of a held or unchecked occurrence

    /// The occurrence had been edited on its own before its delete. The recreated series holds its
    /// slot as its rules give it, so the edit did not come back; the text says so instead of
    /// claiming the occurrence is restored.
    func testAnEditedOccurrenceHeldByTheSeriesSaysItsEditDidNotComeBack() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let series = seriesS
        _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
        var editedOrigin = origin(s1)
        editedOrigin.edited = true
        let edited = UndoSnapshotFixtures.event(title: "Standup (moved)", startDate: s1.addingTimeInterval(1800)).withOccurrenceOrigin(editedOrigin)

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(edited, notCarriedOver: [], calendar: series.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .editedOccurrenceAlreadyHeld)
        XCTAssertEqual(text, UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup (moved)", edited: true))
        XCTAssertTrue(text.contains("its own edit did not come back"), text)
        XCTAssertFalse(text.contains("is already restored by its series"), text)
    }

    /// The rule-less delete record of an occurrence that carries no origin writes the one-off and
    /// says the slot was not checked, as the occurrence record does.
    func testAnOccurrenceDeleteRecordWithoutAnOriginSaysTheSlotWasNotChecked() throws {
        let store = FakeSeriesExceptionsStore()
        let detached = UndoSnapshotFixtures.event(title: "Standup moved", startDate: s1).withOccurrenceOrigin(nil)

        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(detached, calendar: detached.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceOneOffSlotUnchecked(notCarriedOver: []), "round 2: the batch text can say it too")
        XCTAssertEqual(store.log, ["save Standup moved"])
        XCTAssertTrue(text.hasSuffix(". " + UndoOperation.occurrenceSlotUncheckedNote), text)
    }

    /// A one-off event (not an occurrence) says nothing about a series.
    func testAOneOffEventDeleteRecordSaysNothingAboutASeries() throws {
        let store = FakeSeriesExceptionsStore()
        let oneOff = UndoSnapshotFixtures.event(title: "Lunch", startDate: s1)

        let (text, _) = try SeriesExceptionsUndo.undoDeleteEvent(oneOff, calendar: oneOff.calendarIdentifier, in: store)

        XCTAssertEqual(text, UndoOperation.eventRestoredMessage(snapshot: oneOff, newID: "E1"))
    }

    // MARK: - PR #494 round 2

    /// MEDIUM 1: after the series came back from its rules, its occurrence at the recorded slot was
    /// edited and moved three days later in Calendar (it reads as `<series>/RID=<slot>`). It still
    /// holds the slot, though it no longer starts there: the holders are listed around the slot,
    /// a year on each side, and matched by rule slot.
    func testAnOccurrenceOfTheRecreatedSeriesMovedAwayStillHoldsItsSlot() throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = [s0, s1, s2, s3]
        let series = seriesS
        _ = try SeriesExceptionsUndo.undoDeleteEvent(series, calendar: series.calendarIdentifier, in: store)
        let moved = try XCTUnwrap(store.events.first { $0.id == "E1" && $0.start == s1 })
        let rid = "/RID=\(Int(s1.timeIntervalSinceReferenceDate))"
        moved.id = "E1" + rid
        moved.external = "X-E1" + rid
        moved.detached = true
        moved.start = s1.addingTimeInterval(3 * day)
        moved.occurrenceDate = moved.start
        let occurrence = UndoSnapshotFixtures.event(title: "Standup", startDate: s1).withOccurrenceOrigin(origin(s1))

        let (_, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(occurrence, notCarriedOver: [], calendar: series.calendarIdentifier, in: store)

        XCTAssertEqual(outcome, .occurrenceAlreadyHeld)
        XCTAssertEqual(store.log.filter { $0.hasPrefix("save") }, ["save series Standup"], "no second event for that slot")
    }

    /// The listing is bounded: a year (366 days) on each side of the slot.
    func testTheHoldersAreListedAYearOnEachSideOfTheSlot() {
        let range = OccurrenceSlotGuard.listingRange(slot: s1, length: 3600)
        XCTAssertEqual(range.start, s1.addingTimeInterval(-366 * day))
        XCTAssertEqual(range.end, s1.addingTimeInterval(3600 + 366 * day))
        XCTAssertLessThanOrEqual(range.duration, 1460 * day, "one EventKit query")
    }

    /// LOW: a count whose end cannot be shown, ended years before the delete. Placed as open-ended
    /// around the delete, its window held none of its occurrences; when that capture finds none, the
    /// capture lists the window from its first occurrence instead, as before #319.
    func testAnUnknownCountWithNothingAroundTheDeleteIsListedFromItsFirstOccurrence() throws {
        let now = s0
        let first = now.addingTimeInterval(-3650 * day)
        let slots = (0..<10).map { first.addingTimeInterval(Double($0) * 31 * day) }
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots.enumerated().filter { $0.offset != 3 }.map(\.element))
        store.seriesEnd = .unknown

        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now))

        XCTAssertEqual(exceptions.window, UndoPostState.seriesScanWindow(firstStart: first, ruleEnd: nil))
        XCTAssertEqual(exceptions.keptSlots.count, 9)
        XCTAssertFalse(exceptions.seriesStartsBeforeWindow)
        XCTAssertTrue(exceptions.seriesMayContinueAfterWindow)
    }
}
