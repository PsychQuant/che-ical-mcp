import CheMCPKit
import EventKit
import XCTest
@testable import CheICalMCP

/// #244: a delete record used to be the series snapshot whatever the delete removed, so undo of a
/// single-occurrence delete recreated the whole series beside the original (on device: 3
/// occurrences, delete one, 2, undo, 5). The record now says what the delete removed.
final class DeleteUndoTests: XCTestCase {
    private let store = EKEventStore()
    private let firstStart = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86_400

    private final class Lookups { var count = 0 }

    /// `seriesResolves` answers the post-removal lookup and counts how often it was asked.
    private func kind(hadRules: Bool, detached: Bool = false, span: EKSpan, fromFirst: Bool = false,
                      resolves: Bool = true, lookups: Lookups = Lookups()) -> EventRemovalKind {
        EventRemovalKind.of(hadRules: hadRules, isDetached: detached, span: span, fromFirstOccurrence: fromFirst,
                            seriesResolves: { lookups.count += 1; return resolves })
    }

    /// A weekly series of three, as the issue's probe; an occurrence object carries the rules too.
    private func weekly(startingAt start: Date) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = "Standup"
        event.startDate = start
        event.endDate = start.addingTimeInterval(1800)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        return event
    }

    // MARK: - Classification

    func testAOneOffEventIsRemovedWhole() {
        for span in [EKSpan.thisEvent, .futureEvents] {
            XCTAssertEqual(kind(hadRules: false, span: span, resolves: false), .wholeEvent)
        }
    }

    /// D1: span "this" removes one occurrence; undo brings it back as a one-off whatever is left of
    /// the series, so a second series can never come back.
    func testSpanThisOnASeriesRemovesOneOccurrence() {
        for (first, resolves) in [(false, true), (false, false), (true, true), (true, false)] {
            XCTAssertEqual(kind(hadRules: true, span: .thisEvent, fromFirst: first, resolves: resolves), .occurrence)
        }
    }

    /// Verify round 1, findings 1/2/12/22: "whole" needs evidence from before the removal (it
    /// started at the series' first occurrence) and the series gone after it. A lookup that finds
    /// nothing after a span "future" delete from a later occurrence is not proof that nothing is
    /// left: it is refused, never recorded as the series (which undo would recreate beside the
    /// surviving part).
    func testSpanFutureFromALaterOccurrenceIsRefusedEvenWhenTheLookupFindsNothing() {
        let lookups = Lookups()
        XCTAssertEqual(kind(hadRules: true, span: .futureEvents, fromFirst: false, resolves: false, lookups: lookups),
                       .followingOccurrences)
        XCTAssertEqual(kind(hadRules: true, span: .futureEvents, fromFirst: false, resolves: true, lookups: lookups),
                       .followingOccurrences)
        XCTAssertEqual(lookups.count, 0, "nothing the lookup says can make a later start whole")
    }

    /// From the first occurrence nothing is left and the series is recreated whole, but only when
    /// the identifier no longer resolves; a series that still resolves is refused.
    func testSpanFutureFromTheFirstOccurrenceIsWholeOnlyWhenTheSeriesIsGone() {
        let lookups = Lookups()
        XCTAssertEqual(kind(hadRules: true, span: .futureEvents, fromFirst: true, resolves: false, lookups: lookups), .wholeEvent)
        XCTAssertEqual(kind(hadRules: true, span: .futureEvents, fromFirst: true, resolves: true, lookups: lookups),
                       .followingOccurrences)
        XCTAssertEqual(lookups.count, 2)
    }

    /// A detached occurrence addressed by its own identifier has no rules. Span "future" removes the
    /// following occurrences of its series too (checked on iCloud, 2026-10-07: the 3rd went with
    /// the edited 2nd), which its snapshot does not hold: restoring the snapshot alone would leave
    /// them out silently, so it is refused.
    func testADetachedOccurrenceIsAnOccurrenceAndWithSpanFutureIsRefused() {
        let lookups = Lookups()
        for resolves in [true, false] {
            XCTAssertEqual(kind(hadRules: false, detached: true, span: .thisEvent, resolves: resolves, lookups: lookups), .occurrence)
            XCTAssertEqual(kind(hadRules: false, detached: true, span: .futureEvents, fromFirst: true, resolves: resolves, lookups: lookups),
                           .followingOccurrences)
        }
        XCTAssertEqual(lookups.count, 0)
    }

    // MARK: - Evidence taken before the removal

    /// The record site passes the two events it resolved; the facts come from them, so the
    /// classification cannot be fed the wrong flag.
    func testTheFactsComeFromTheEventsBeforeTheRemoval() {
        let series = weekly(startingAt: firstStart)
        let first = DeletedEventSnapshots(series: series, removed: weekly(startingAt: firstStart))
        let second = DeletedEventSnapshots(series: series, removed: weekly(startingAt: firstStart.addingTimeInterval(week)))

        XCTAssertEqual(first.kind(span: .futureEvents, seriesResolves: { false }), .wholeEvent)
        XCTAssertEqual(second.kind(span: .futureEvents, seriesResolves: { false }), .followingOccurrences)
        XCTAssertEqual(second.kind(span: .thisEvent, seriesResolves: { false }), .occurrence)

        let oneOff = EKEvent(eventStore: store)
        oneOff.calendar = series.calendar
        oneOff.title = "Review"
        oneOff.startDate = firstStart
        oneOff.endDate = firstStart.addingTimeInterval(1800)
        XCTAssertEqual(DeletedEventSnapshots(series: oneOff, removed: oneOff).kind(span: .futureEvents, seriesResolves: { true }),
                       .wholeEvent)
    }

    /// On iCloud the series object keeps its original first slot after that occurrence was deleted
    /// on its own (checked 2026-10-07), so span "future" from the first remaining occurrence is not
    /// "from the first": refused, instead of recreating the series with the deleted occurrence in it.
    /// Unreachable on iCloud while #284 stands (the delete fails as "Event not found"); re-check
    /// the premise on device when #284 is fixed.
    func testTheFirstSlotIsTheSeriesStartNotTheFirstRemainingOccurrence() {
        let series = weekly(startingAt: firstStart)
        let firstRemaining = weekly(startingAt: firstStart.addingTimeInterval(week))
        XCTAssertEqual(DeletedEventSnapshots(series: series, removed: firstRemaining).kind(span: .futureEvents, seriesResolves: { false }),
                       .followingOccurrences)
    }

    // MARK: - Record shapes

    /// PR #282 round 4, finding 2: the event batch builder (`deleteEventsBatch`) records only what
    /// this returns, and every kind it returns may be moved to run last when its write fails in a
    /// batch undo (#248): a whole event or an occurrence restores one new item and reads no other
    /// member; the marker never runs.
    func testEveryRemovalKindRecordsADeleteThatABatchUndoMayRunLast() {
        let series = weekly(startingAt: firstStart)
        let snapshots = DeletedEventSnapshots(series: series, removed: weekly(startingAt: firstStart.addingTimeInterval(week)))
        XCTAssertEqual(EventRemovalKind.allCases.count, 3)
        for kind in EventRemovalKind.allCases {
            let record = snapshots.record(for: kind)
            switch record {
            case .deleteEvent, .deleteOccurrence, .deleteFollowingOccurrences:
                XCTAssertTrue(record.mayRunLastAfterAFailure, "\(kind)")
            default:
                XCTFail("\(kind) recorded \(record)")
            }
        }
    }

    /// As the #208 move copy-out: the occurrence without its rules, at its own slot.
    func testAnOccurrenceDeleteRecordsTheOccurrenceWithoutRules() throws {
        let series = weekly(startingAt: firstStart)
        let second = weekly(startingAt: firstStart.addingTimeInterval(week))
        let record = DeletedEventSnapshots(series: series, removed: second).record(for: .occurrence)

        guard case .deleteOccurrence(let snapshot, let notCarriedOver) = record else { return XCTFail("\(record)") }
        XCTAssertNil(snapshot.recurrenceRules, "no second series")
        XCTAssertEqual(snapshot.startDate, second.startDate)
        XCTAssertEqual(snapshot.endDate, second.endDate)
        XCTAssertEqual(snapshot.title, "Standup")
        XCTAssertEqual(notCarriedOver, [])
    }

    /// Verify round 1, finding 6: an occurrence of a series reads the series' absolute alarm date,
    /// which a later occurrence has passed. As the #253 split path does, an absolute alarm goes to
    /// the occurrence's start and is reported; other alarms are kept.
    ///
    /// Verify round 2, findings 7/15 asked for the series-start shift instead. That shift was the
    /// move path's rule only until 2a40986 (#253 verify round 2, maintainer decision D2-b), which
    /// replaced it with this one because its base was unreliable. This test pins that the restore
    /// applies the split rule (`copyOutAlarms(of:isSplit: true)`) to a series occurrence; it does
    /// not pin the move path's own call site, whose `isSplit` comes from its executor (verify
    /// round 3, finding 5).
    func testAnOccurrenceRestoreMovesAbsoluteAlarmsToItsStart() throws {
        let alarmDate = firstStart.addingTimeInterval(-3600)
        let series = weekly(startingAt: firstStart)
        series.addAlarm(EKAlarm(absoluteDate: alarmDate))
        let second = weekly(startingAt: firstStart.addingTimeInterval(week))
        second.addAlarm(EKAlarm(absoluteDate: alarmDate))
        second.addAlarm(EKAlarm(relativeOffset: -900))

        guard case .deleteOccurrence(let snapshot, let notCarriedOver) = DeletedEventSnapshots(series: series, removed: second)
            .record(for: .occurrence) else { return XCTFail() }
        XCTAssertEqual(notCarriedOver, ["absolute_alarms"])
        XCTAssertEqual(snapshot.alarms.map(\.absoluteDate), [nil, nil])
        XCTAssertEqual(Set(snapshot.alarms.map(\.relativeOffset)), [0, -900])

        let split = EventKitManager.copyOutAlarms(of: second, isSplit: true)
        XCTAssertEqual(snapshot.alarms, split.alarms, "the alarms a move that splits this occurrence out would write")
        XCTAssertEqual(notCarriedOver, split.notCarriedOver)
    }

    /// Nothing is reported when nothing was moved: relative alarms only.
    func testAnOccurrenceWithoutAbsoluteAlarmsReportsNothing() throws {
        let series = weekly(startingAt: firstStart)
        let second = weekly(startingAt: firstStart.addingTimeInterval(week))
        second.addAlarm(EKAlarm(relativeOffset: -900))

        guard case .deleteOccurrence(let snapshot, let notCarriedOver) = DeletedEventSnapshots(series: series, removed: second)
            .record(for: .occurrence) else { return XCTFail() }
        XCTAssertEqual(notCarriedOver, [])
        XCTAssertEqual(snapshot.alarms.map(\.relativeOffset), [-900])
    }

    /// A one-off event, or a detached occurrence addressed by its own identifier, carries its own
    /// alarm dates (the move path keeps them too).
    func testAOneOffKeepsItsAbsoluteAlarms() throws {
        let alarmDate = firstStart.addingTimeInterval(-3600)
        let oneOff = EKEvent(eventStore: store)
        oneOff.calendar = EKCalendar(for: .event, eventStore: store)
        oneOff.title = "Review"
        oneOff.startDate = firstStart
        oneOff.endDate = firstStart.addingTimeInterval(1800)
        oneOff.addAlarm(EKAlarm(absoluteDate: alarmDate))

        guard case .deleteOccurrence(let snapshot, let notCarriedOver) = DeletedEventSnapshots(series: oneOff, removed: oneOff)
            .record(for: .occurrence) else { return XCTFail() }
        XCTAssertEqual(notCarriedOver, [])
        XCTAssertEqual(snapshot.alarms.map(\.absoluteDate), [alarmDate])
    }

    func testAWholeEventDeleteRecordsTheSeriesWithItsRules() throws {
        let series = weekly(startingAt: firstStart)
        let record = DeletedEventSnapshots(series: series, removed: series).record(for: .wholeEvent)

        guard case .deleteEvent(let snapshot) = record else { return XCTFail("\(record)") }
        XCTAssertEqual(snapshot.recurrenceRules?.count, 1)
        XCTAssertEqual(snapshot.startDate, firstStart)
    }

    func testAFollowingOccurrencesDeleteRecordsOnlyAMarker() {
        let series = weekly(startingAt: firstStart)
        let record = DeletedEventSnapshots(series: series, removed: weekly(startingAt: firstStart.addingTimeInterval(week)))
            .record(for: .followingOccurrences)

        guard case .deleteFollowingOccurrences(let title) = record else { return XCTFail("\(record)") }
        XCTAssertEqual(title, "Standup")
        XCTAssertNil(record.undoPostState, "nothing is compared, because nothing is written")
        XCTAssertNil(record.redoPostState)
    }

    func testTheNewRecordsHaveNoPostStateToCompare() {
        XCTAssertNil(UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Standup"), notCarriedOver: []).undoPostState,
                     "undo recreates; there is no item to overwrite")
    }

    // MARK: - Texts

    func testHistoryDescriptionsSayWhatUndoWillDo() {
        let occurrence = UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Stand\u{202E}up 'x'"), notCarriedOver: [])
        XCTAssertEqual(occurrence.description, "Deleted occurrence of event: Standup 'x' (undo restores it as a one-off event)")
        let marker = UndoOperation.deleteFollowingOccurrences(title: "Stand\u{200B}up")
        XCTAssertEqual(marker.description, "Deleted occurrences of recurring event: Standup (undo not available)")
        // Verify round 4, findings 11/15, and round 5, finding 7: a series record says what its undo
        // brings back before it runs.
        let rules = "occurrences deleted on their own earlier come back, edited ones without their edits"
        let series = UndoOperation.deleteEvent(snapshot: EventSnapshot(from: weekly(startingAt: firstStart)))
        XCTAssertEqual(series.description, "Deleted event: Standup (undo recreates the series from its rules: \(rules))")
        let oneOff = UndoOperation.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Review"))
        XCTAssertEqual(oneOff.description, "Deleted event: Review", "a one-off record is listed as before")
        // Round 5, findings 1/2: so does a delete_events_batch record that removed a series whole,
        // counting series at any depth; one without is listed as before.
        XCTAssertEqual(UndoOperation.batch([series, occurrence, oneOff]).description,
                       "Batch (3 operations; undo recreates 1 series from its rules: \(rules))")
        XCTAssertEqual(UndoOperation.batch([.batch([series]), series]).description,
                       "Batch (2 operations; undo recreates 2 series from their rules: \(rules))", "nested batches are walked")
        XCTAssertEqual(UndoOperation.batch([oneOff, occurrence]).description, "Batch (2 operations)")
        // Round 6, finding 6: only series count, not an occurrence restore that moved an alarm.
        let moved = UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Standup"), notCarriedOver: ["absolute_alarms"])
        XCTAssertEqual(UndoOperation.batch([series, moved]).description,
                       "Batch (2 operations; undo recreates 1 series from its rules: \(rules))")
        XCTAssertEqual(UndoOperation.batch([moved, oneOff]).description, "Batch (2 operations)")
        // Round 6, findings 1/2/4: a batch holding a member undo refuses, at any depth, is refused
        // before any member writes and discarded, so it promises no restore (one series deleted from
        // its 3rd occurrence and then from its 1st in one batch gives [marker, series]).
        let refused = "undo not available: a member deleted an occurrence and the following ones of a recurring event"
        XCTAssertEqual(UndoOperation.batch([series, marker]).description, "Batch (2 operations; \(refused))")
        XCTAssertEqual(UndoOperation.batch([.batch([marker]), series]).description, "Batch (2 operations; \(refused))",
                       "a refusal at any depth")
        XCTAssertEqual(UndoOperation.batch([oneOff, occurrence, marker]).description, "Batch (3 operations; \(refused))")
        // Round 6, findings 7/14: a batch of one (delete_events_batch records one even for one event).
        XCTAssertEqual(UndoOperation.batch([series]).description,
                       "Batch (1 operation; undo recreates 1 series from its rules: \(rules))")
        XCTAssertEqual(UndoOperation.batch([oneOff]).description, "Batch (1 operation)")
    }

    /// The undo text reports a moved absolute alarm the way the move path reports it.
    func testTheRestoreMessageReportsWhatWasNotCarriedOver() {
        XCTAssertEqual(UndoOperation.occurrenceRestoredMessage(title: "Stand\u{202E}up", newID: "n1", notCarriedOver: []),
                       "Undone: restored the deleted occurrence of 'Standup' as a one-off event (new ID: n1)")
        XCTAssertEqual(UndoOperation.occurrenceRestoredMessage(title: "Standup", newID: "n1", notCarriedOver: ["absolute_alarms"]),
                       "Undone: restored the deleted occurrence of 'Standup' as a one-off event (new ID: n1). Not carried over: absolute_alarms (an absolute-date alarm of the series is now an alarm at the occurrence's start)")
    }

    /// Verify round 2, finding 5: a batch undo names what its restored occurrences did not carry
    /// over, once, as the single undo does; a batch that moved nothing says only the count.
    func testABatchUndoTextNamesWhatItsRestoredOccurrencesDidNotCarryOver() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup")
        let moved = UndoOperation.deleteOccurrence(snapshot: snapshot, notCarriedOver: ["absolute_alarms"])
        let kept = UndoOperation.deleteOccurrence(snapshot: snapshot, notCarriedOver: [])
        XCTAssertEqual(UndoOperation.batchUndoneMessage(members: [moved, kept, moved], count: 3),
                       "Undone batch (3 operations). Not carried over: absolute_alarms (an absolute-date alarm of a series is now an alarm at its restored occurrence's start)")
        XCTAssertEqual(UndoOperation.batchUndoneMessage(members: [.batch([kept, moved])], count: 2),
                       "Undone batch (2 operations). Not carried over: absolute_alarms (an absolute-date alarm of a series is now an alarm at its restored occurrence's start)",
                       "nested batches are walked")
        XCTAssertEqual(UndoOperation.batchUndoneMessage(members: [kept, .deleteEvent(snapshot: snapshot)], count: 2),
                       "Undone batch (2 operations)")
    }

    /// Verify round 3, findings 3/7/9 (#285): a recurring event comes back from the rules in its
    /// snapshot, which hold no occurrence deleted or edited on its own before the delete, so the
    /// undo text says so; a one-off event's text is unchanged.
    func testAWholeSeriesRestoreSaysItCameBackFromItsRules() {
        let series = EventSnapshot(from: weekly(startingAt: firstStart))
        XCTAssertEqual(UndoOperation.eventRestoredMessage(snapshot: series, newID: "n1"),
                       "Undone: restored event 'Standup' (new ID: n1). Restored from the series rules: an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit, and undoing the earlier delete of that occurrence as well adds it a second time")
        XCTAssertEqual(UndoOperation.eventRestoredMessage(snapshot: UndoSnapshotFixtures.event(title: "Stand\u{202E}up"), newID: "n1"),
                       "Undone: restored event 'Standup' (new ID: n1)")
    }

    /// The batch text names it once too, after `absolute_alarms`, for a series member at any depth.
    func testABatchUndoTextSaysASeriesCameBackFromItsRules() {
        let series = UndoOperation.deleteEvent(snapshot: EventSnapshot(from: weekly(startingAt: firstStart)))
        let oneOff = UndoOperation.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Review"))
        let moved = UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Standup"), notCarriedOver: ["absolute_alarms"])
        let rules = "Restored from the series rules: an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit, and undoing the earlier delete of that occurrence as well adds it a second time"
        XCTAssertEqual(UndoOperation.batchUndoneMessage(members: [oneOff, .batch([series])], count: 2),
                       "Undone batch (2 operations). " + rules)
        XCTAssertEqual(UndoOperation.batchUndoneMessage(members: [series, moved], count: 2),
                       "Undone batch (2 operations). Not carried over: absolute_alarms (an absolute-date alarm of a series is now an alarm at its restored occurrence's start). " + rules)
        XCTAssertEqual(UndoOperation.batchUndoneMessage(members: [oneOff], count: 1), "Undone batch (1 operation)")
    }

    /// The whole-event arm of `executeUndo` reports through that text (pinned: it needs an
    /// authorized store to run).
    func testTheWholeEventUndoArmReportsTheRulesRestore() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func executeUndo(_ operation: UndoOperation)", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let arm = try XCTUnwrap(SourcePins.ranges(of: "case .deleteEvent(let snapshot):", in: body).first)
        let next = try XCTUnwrap(SourcePins.ranges(of: "case .deleteOccurrence(", in: body).first)
        let message = SourcePins.ranges(ofPattern: #"return\s+UndoOperation\.eventRestoredMessage\(snapshot:\s*snapshot,\s*newID:"#, in: body)
        XCTAssertEqual(message.count, 1)
        if let message = message.first {
            XCTAssertGreaterThan(message.lowerBound, arm.lowerBound)
            XCTAssertLessThan(message.lowerBound, next.lowerBound, "in the whole-event arm")
        }
    }

    /// The batch arm of `executeUndo` reports through that text (it needs an authorized store to
    /// run, so it is pinned here).
    func testTheBatchUndoArmReportsItsMembers() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func executeUndo(_ operation: UndoOperation)", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let arm = try XCTUnwrap(SourcePins.ranges(of: "case .batch(let ops):", in: body).first)
        let message = SourcePins.ranges(ofPattern: #"return\s+UndoOperation\.batchUndoneMessage\(members:\s*ops,\s*count:\s*results\.count\)"#, in: body)
        XCTAssertEqual(message.count, 1)
        if let message = message.first { XCTAssertGreaterThan(message.lowerBound, arm.lowerBound) }
    }

    // MARK: - Refusals (D2, D3)

    func testUndoOfTheMarkerIsRefusedPermanently() {
        let error = UndoOperation.followingOccurrencesDeleteRefusal(title: "Standup\u{202E}")
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard, "D2: discarded so earlier operations stay undoable")
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.hasPrefix("Cannot undo the delete of the recurring event 'Standup'"), message)
        XCTAssertTrue(message.contains("the following occurrences"), message)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("earlier operations remain undoable"), message)
        XCTAssertTrue(message.contains("in Calendar"), message)
        XCTAssertFalse(message.contains("discard_id"), "the entry is already discarded")
    }

    /// D3: a batch that holds such a delete is refused before any member writes, and discarded.
    /// Verify round 1, finding 3: the text claims only that, not atomicity (a write that fails part
    /// way through is #248).
    func testABatchMemberThatCannotBeRestoredRefusesTheWholeBatch() throws {
        let error = try XCTUnwrap(UndoOperation.deleteFollowingOccurrences(title: "Standup").batchMemberUndoRefusal)
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertTrue(message.hasPrefix("Cannot undo this batch"), message)
        XCTAssertTrue(message.contains("'Standup'"), message)
        XCTAssertTrue(message.contains("none of the batch's events were restored"), message)
        XCTAssertTrue(message.contains("earlier operations remain undoable"), message)
        XCTAssertFalse(message.contains("whole or not at all"), message)
    }

    func testRestorableBatchMembersPassTheCheck() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup")
        XCTAssertNil(UndoOperation.deleteEvent(snapshot: snapshot).batchMemberUndoRefusal)
        XCTAssertNil(UndoOperation.deleteOccurrence(snapshot: snapshot, notCarriedOver: []).batchMemberUndoRefusal)
        XCTAssertNil(UndoOperation.createEvent(id: "e", title: "Standup", created: snapshot).batchMemberUndoRefusal)
    }

    // MARK: - Record sites (source pins: verify round 1 finding 19, round 2 findings 12/16/20/25/26)

    /// Both delete paths take the snapshots before the removal and classify through
    /// `DeletedEventSnapshots` after it; an in-memory store cannot run them, so the order is pinned
    /// here, branch by branch: every removal has its own snapshot just before it, and the
    /// classification comes after the last removal (before it, the lookup would always find the
    /// series and every span "future" delete would be refused).
    func testBothDeletePathsSnapshotBeforeTheyRemoveAndClassifyAfter() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        for (name, identifier) in [("func deleteEvent(identifier:", "identifier"), ("func deleteEventsBatch(", "item.identifier")] {
            let body = try XCTUnwrap(SourcePins.body(of: name, in: source), name)
            let snapshots = SourcePins.ranges(of: "DeletedEventSnapshots(series:", in: body)
            let removals = SourcePins.ranges(of: "eventStore.remove(", in: body)
            XCTAssertEqual(snapshots.count, 2, "\(name): one snapshot per removing branch")
            XCTAssertEqual(removals.count, snapshots.count, "\(name): one removal per snapshot")
            for (index, (snapshot, removal)) in zip(snapshots, removals).enumerated() {
                XCTAssertLessThan(snapshot.lowerBound, removal.lowerBound, "\(name), branch \(index): snapshot before the removal")
                if index + 1 < snapshots.count {
                    XCTAssertLessThan(removal.lowerBound, snapshots[index + 1].lowerBound, "\(name), branch \(index): its own snapshot")
                }
            }
            let classify = SourcePins.ranges(ofPattern: #"\.kind\(span:\s*span,\s*seriesResolves:\s*\{\s*seriesResolves\(identifier:\s*"# + NSRegularExpression.escapedPattern(for: identifier) + #"\s*\)\s*\}\)"#, in: body)
            XCTAssertEqual(classify.count, 1, "\(name) classifies once, looking its own identifier up again")
            if let classify = classify.first, let last = removals.last {
                XCTAssertGreaterThan(classify.lowerBound, last.lowerBound, "\(name): classified after the removal")
            }
        }
    }

    /// Verify round 1, finding 17: the post-removal lookup marks the store stale before it reads.
    func testThePostRemovalLookupMarksTheStoreStaleFirst() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func seriesResolves(identifier:", in: try SourcePins.source("EventKit/DeleteUndo.swift")))
        let stale = try XCTUnwrap(SourcePins.ranges(of: "markNeedsRefresh()", in: body).first)
        let read = try XCTUnwrap(SourcePins.ranges(of: "freshEvent(id: identifier)", in: body).first)
        XCTAssertLessThan(stale.lowerBound, read.lowerBound)
    }
}
