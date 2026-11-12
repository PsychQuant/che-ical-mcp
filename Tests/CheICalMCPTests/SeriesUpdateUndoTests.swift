import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #263 (maintainer decision 2026-11-12): the undo of an `update_event` with span "all" on an iCloud
/// series, the first recurring update undo restores. Pure parts: which updates get the restorable
/// record, the iCloud gate, whether the listing covers the series, the comparison of the series'
/// exceptions, the refusals, and the read-back after the write.
final class SeriesUpdateUndoTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 820_000_000)
    private let calendar = UndoSnapshotFixtures.newCalendar()

    private func slot(_ week: Int) -> Date { start.addingTimeInterval(Double(week) * 7 * day) }

    private func snapshot(_ title: String, at date: Date? = nil, weekly: Int? = nil) -> EventSnapshot {
        UndoSnapshotFixtures.event(title: title, weeklyOccurrences: weekly, startDate: date ?? start, calendar: calendar)
    }

    private var window: DateInterval { DateInterval(start: start.addingTimeInterval(-day), duration: 1460 * day) }

    private func exceptions(kept: [Int], detached: [(Int, String)] = []) -> SeriesExceptions {
        SeriesExceptions(window: window, keptSlots: kept.map(slot),
                         detached: detached.map { DetachedOccurrence(slot: slot($0.0), snapshot: snapshot($0.1, at: slot($0.0))) })
    }

    private func record(fields: [String] = ["title"], before: SeriesExceptions? = nil, after: SeriesExceptions? = nil) -> SeriesUpdateRecord {
        let after = after ?? exceptions(kept: [0, 2, 4], detached: [(3, "Own")])
        return SeriesUpdateRecord(id: "S", externalIdentifier: "X-S", old: snapshot("Before", weekly: 5),
                                  saved: snapshot("After", weekly: 5), fields: fields,
                                  before: before ?? after, after: after)
    }

    private func current(id: String? = "S", external: String? = "X-S", hasRules: Bool = true, isDetached: Bool = false,
                         rules: [RecurrenceRuleSnapshot]? = nil, iCloud: Bool = true, covered: Bool = true,
                         exceptions: SeriesExceptions?) -> SeriesUpdateUndo.Current {
        SeriesUpdateUndo.Current(eventIdentifier: id, externalIdentifier: external, hasRules: hasRules, isDetached: isDetached,
                                 rules: rules ?? snapshot("After", weekly: 5).recurrenceRules, isICloud: iCloud,
                                 covered: covered, exceptions: exceptions)
    }

    // MARK: - Which updates are restorable

    func testOnlyTitleNotesAndLocationAreRestorable() {
        XCTAssertEqual(SeriesUpdateUndo.restorableFields(requested: ["event_id", "span", "title"]), ["title"])
        XCTAssertEqual(SeriesUpdateUndo.restorableFields(requested: ["event_id", "span", "location", "notes", "title"]),
                       ["title", "notes", "location"], "in a fixed order")
        for other in ["start_time", "end_time", "all_day", "timezone", "clear_timezone", "url", "alarms_minutes_offsets",
                      "structured_location", "calendar_name", "calendar_source", "recurrence", "clear_recurrence",
                      "occurrence_date", "availability"] {
            XCTAssertNil(SeriesUpdateUndo.restorableFields(requested: ["event_id", "span", "title", other]), other)
        }
        XCTAssertNil(SeriesUpdateUndo.restorableFields(requested: ["event_id", "span"]), "an update that wrote nothing")
    }

    func testTheRecordIsTakenOnlyForAWholeSeriesUpdateThroughTheSeriesOwnObjectOnICloud() {
        func recordable(kind: RecurringUpdateKind? = .series, whole: Bool = true, own: Bool = false, standIn: Bool = false,
                        iCloud: Bool = true, coordinates: Bool = false,
                        requested: Set<String> = ["event_id", "span", "title"]) -> [String]? {
            SeriesUpdateUndo.recordable(kind: kind, wholeSeriesCall: whole, throughOwnOccurrence: own, viaStandIn: standIn,
                                        requested: requested, isICloud: iCloud, placeHasCoordinates: coordinates)
        }
        XCTAssertEqual(recordable(), ["title"])
        for kind: RecurringUpdateKind in [.occurrence, .future, .rulesAdded, .rulesRemoved] {
            XCTAssertNil(recordable(kind: kind), "\(kind) stays refused")
        }
        XCTAssertNil(recordable(kind: nil), "a one-off update has its own record")
        XCTAssertNil(recordable(whole: false), "span future from the first occurrence is not span all")
        XCTAssertNil(recordable(own: true), "through an occurrence's own identifier (#416, #428)")
        XCTAssertNil(recordable(standIn: true), "through a stand-in (#326)")
        XCTAssertNil(recordable(iCloud: false), "every other source stays refused")
        XCTAssertNil(recordable(requested: ["event_id", "span", "title", "start_time"]))
        XCTAssertNil(recordable(coordinates: true, requested: ["event_id", "span", "location"]),
                     "a location string written over a place with coordinates cannot be written back with them")
        XCTAssertEqual(recordable(coordinates: true), ["title"], "coordinates matter only when the location is written")
    }

    /// #263 verify r1 (A): the two measured shapes of an occurrence edited on its own, judged from the
    /// listings before and after the save, through the production rule. Anything else keeps the marker.
    private func occurrence(title: String = "Weekly", notes: String? = nil, location: String? = nil,
                            lat: Double? = nil, at week: Int = 3) -> DetachedOccurrence {
        let event = EKEvent(eventStore: SharedTestStore.store)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.location = location
        event.startDate = slot(week)
        event.endDate = slot(week).addingTimeInterval(3600)
        if let lat {
            let place = EKStructuredLocation(title: location ?? "Place")
            place.geoLocation = CLLocation(latitude: lat, longitude: 121.5)
            event.structuredLocation = place
        }
        return DetachedOccurrence(slot: slot(week), snapshot: EventSnapshot(from: event, includeRecurrence: false))
    }

    private func listing(_ detached: [DetachedOccurrence]) -> SeriesExceptions {
        SeriesExceptions(window: window, keptSlots: [slot(0)], detached: detached)
    }

    private func seriesWith(notes: String?, location: String? = nil, title: String = "Weekly") -> EventSnapshot {
        let event = EKEvent(eventStore: SharedTestStore.store)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.location = location
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        return EventSnapshot(from: event)
    }

    private func followOrKeep(before: [DetachedOccurrence], after: [DetachedOccurrence], old: EventSnapshot,
                              written: [String: String]) -> Bool {
        SeriesUpdateUndo.occurrencesFollowOrKeep(before: listing(before), after: listing(after), old: old,
                                                 written: written, fields: SeriesUpdateUndo.restorableOrder.filter { written[$0] != nil })
    }

    func testAnOccurrenceThatFollowedOrKeptItsOwnValueIsRestorable() {
        let old = seriesWith(notes: "Default")
        XCTAssertTrue(followOrKeep(before: [occurrence(notes: "Default")], after: [occurrence(notes: "New")], old: old,
                                   written: ["notes": "New"]), "follows: the series' old value, then the new one")
        XCTAssertTrue(followOrKeep(before: [occurrence(title: "Own")], after: [occurrence(title: "Own")], old: seriesWith(notes: nil),
                                   written: ["title": "Changed"]), "keeps: an own title different from both")
        XCTAssertTrue(followOrKeep(before: [], after: [], old: old, written: ["notes": "New"]), "no occurrence edited on its own")
    }

    /// Codex's scenario: the series' notes are Default, occurrence 3 has its own Private, the update
    /// writes New. Whether it took New or kept Private, a later shape decides.
    func testAnOwnValueTheWriteReplacedKeepsTheMarker() {
        let old = seriesWith(notes: "Default")
        XCTAssertFalse(followOrKeep(before: [occurrence(notes: "Private")], after: [occurrence(notes: "New")], old: old,
                                    written: ["notes": "New"]), "its own Private was replaced: the inverse would write Default")
        XCTAssertTrue(followOrKeep(before: [occurrence(notes: "Private")], after: [occurrence(notes: "Private")], old: old,
                                   written: ["notes": "New"]), "Private kept: neither write touches it")
    }

    func testAnOccurrenceAlreadyHoldingTheWrittenValueKeepsTheMarker() {
        let old = seriesWith(notes: nil, location: "Room A")
        XCTAssertFalse(followOrKeep(before: [occurrence(location: "Room B")], after: [occurrence(location: "Room B")], old: old,
                                    written: ["location": "Room B"]), "it cannot be told from one that followed")
        XCTAssertFalse(followOrKeep(before: [occurrence(title: "New")], after: [occurrence(title: "New")], old: seriesWith(notes: nil),
                                    written: ["title": "New"]))
    }

    func testAnOccurrenceThatDidNotFollowOrChangedOtherwiseKeepsTheMarker() {
        let old = seriesWith(notes: "Default")
        XCTAssertFalse(followOrKeep(before: [occurrence(notes: "Default")], after: [occurrence(notes: "Default")], old: old,
                                    written: ["notes": "New"]), "it had the old value and did not take the new one")
        XCTAssertFalse(followOrKeep(before: [occurrence(notes: "Default")], after: [occurrence(notes: "Other")], old: old,
                                    written: ["notes": "New"]))
        XCTAssertFalse(followOrKeep(before: [occurrence(title: "Own", notes: "Default")], after: [occurrence(title: "Own 2", notes: "New")], old: old,
                                    written: ["notes": "New"]), "another field changed too")
        XCTAssertFalse(followOrKeep(before: [occurrence(notes: "Default")], after: [], old: old, written: ["notes": "New"]),
                       "the detached slots before and after differ")
        XCTAssertFalse(followOrKeep(before: [], after: [occurrence(notes: "New")], old: old, written: ["notes": "New"]))
        XCTAssertFalse(followOrKeep(before: [occurrence(notes: "Default", at: 3)], after: [occurrence(notes: "New", at: 4)], old: old,
                                    written: ["notes": "New"]))
        XCTAssertFalse(SeriesUpdateUndo.occurrencesFollowOrKeep(before: listing([]), after: listing([]), old: old, written: [:], fields: ["notes"]),
                       "a field without its written value (fail closed)")
    }

    func testNilAndEmptyTextAreTheSameInTheRule() {
        XCTAssertTrue(followOrKeep(before: [occurrence(notes: nil)], after: [occurrence(notes: "New")], old: seriesWith(notes: ""),
                                   written: ["notes": "New"]))
        XCTAssertTrue(followOrKeep(before: [occurrence(notes: "Old")], after: [occurrence(notes: "")], old: seriesWith(notes: "Old"),
                                   written: ["notes": ""]), "a cleared field that reads back as empty")
    }

    func testAnEditedOccurrenceWithCoordinatesKeepsTheMarkerWhenLocationIsWritten() {
        let old = seriesWith(notes: nil, location: "Room A")
        XCTAssertFalse(followOrKeep(before: [occurrence(location: "Room A", lat: 25.0)], after: [occurrence(location: "Room B")], old: old,
                                    written: ["location": "Room B"]))
        XCTAssertTrue(followOrKeep(before: [occurrence(notes: "Default", lat: 25.0)], after: [occurrence(notes: "New", lat: 25.0)],
                                   old: seriesWith(notes: "Default"), written: ["notes": "New"]), "only when location is written")
    }

    func testTheWrittenValuesComeFromTheCall() {
        XCTAssertEqual(SeriesUpdateUndo.writtenValues(title: "T", notes: nil, location: ""), ["title": "T", "location": ""])
    }

    func testThisRecordComparesNilAndEmptyTextAsTheSame() {
        let a = seriesWith(notes: nil, location: nil), b = seriesWith(notes: "", location: "")
        XCTAssertEqual(SeriesUpdateUndo.changedFields(a, b), [])
        XCTAssertEqual(SeriesUpdateUndo.changedFields(a, seriesWith(notes: "x")), ["notes"])
        XCTAssertFalse(a.changedFields(in: b, restoring: nil).isEmpty, "#236's guard is unchanged")
    }

    /// The #416 and #428 routes write through an occurrence's own object: never the series kind.
    func testOwnOccurrenceRoutesNeverClassifyAsTheSeriesKind() {
        for span: EKSpan in [.thisEvent, .futureEvents] {
            for (had, after) in [(true, true), (false, true), (false, false)] {
                XCTAssertNotEqual(RecurringUpdateKind.of(hadRules: had, hasRulesAfter: after, onOccurrence: true, span: span), .series)
            }
        }
    }

    // MARK: - The iCloud gate

    func testICloudIsACalDAVSourceTitledICloudOrTheLegacyType() {
        XCTAssertTrue(SeriesUpdateUndo.isICloud(sourceType: .calDAV, sourceTitle: "iCloud"))
        XCTAssertTrue(SeriesUpdateUndo.isICloud(sourceType: .mobileMe, sourceTitle: "iCloud"))
        XCTAssertTrue(SeriesUpdateUndo.isICloud(sourceType: .mobileMe, sourceTitle: nil))
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: .calDAV, sourceTitle: "Google"))
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: .calDAV, sourceTitle: "icloud"), "exactly the title iCloud shows")
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: .calDAV, sourceTitle: nil))
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: .exchange, sourceTitle: "iCloud"))
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: .local, sourceTitle: "iCloud"))
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: .subscribed, sourceTitle: "iCloud"))
        XCTAssertFalse(SeriesUpdateUndo.isICloud(sourceType: nil, sourceTitle: "iCloud"), "no source refuses")
    }

    /// Verify r1: the gate reads the series' own calendar; one with no account is not iCloud.
    func testAnEventWithoutAnAccountIsNotAnICloudSeries() {
        let event = EKEvent(eventStore: SharedTestStore.store)
        XCTAssertFalse(EventKitManager.isICloudSeries(event), "no calendar")
        event.calendar = calendar
        XCTAssertFalse(EventKitManager.isICloudSeries(event), "a calendar with no source")
    }

    // MARK: - Coverage

    func testTheListingMustCoverTheWholeSeries() {
        let listed = exceptions(kept: [0, 1, 2])
        XCTAssertTrue(SeriesUpdateUndo.covers(listed, firstStart: start, end: .endsAt(slot(10))))
        XCTAssertTrue(SeriesUpdateUndo.covers(listed, firstStart: start, end: .endsBy(slot(10))))
        XCTAssertFalse(SeriesUpdateUndo.covers(listed, firstStart: start, end: .open), "a series with no end is never covered")
        XCTAssertFalse(SeriesUpdateUndo.covers(listed, firstStart: start, end: .unknown))
        XCTAssertFalse(SeriesUpdateUndo.covers(listed, firstStart: start, end: .endsAt(window.end)), "an end at the window's end")
        XCTAssertFalse(SeriesUpdateUndo.covers(listed, firstStart: window.start.addingTimeInterval(-1), end: .endsAt(slot(10))))
        var before = listed; before.seriesStartsBeforeWindow = true
        XCTAssertFalse(SeriesUpdateUndo.covers(before, firstStart: start, end: .endsAt(slot(10))))
        var after = listed; after.seriesContinuesAfterWindow = true
        XCTAssertFalse(SeriesUpdateUndo.covers(after, firstStart: start, end: .endsAt(slot(10))))
        var maybe = listed; maybe.seriesMayContinueAfterWindow = true
        XCTAssertFalse(SeriesUpdateUndo.covers(maybe, firstStart: start, end: .endsBy(slot(10))))
    }

    // MARK: - The exceptions comparison

    func testTheSameExceptionsShowNoDifference() {
        let a = exceptions(kept: [0, 2, 4], detached: [(3, "Own")])
        XCTAssertTrue(SeriesUpdateUndo.diff(recorded: a, current: exceptions(kept: [4, 0, 2], detached: [(3, "Own")])).isEmpty,
                      "slots compare as sets")
    }

    func testAnOccurrenceDeletedSinceIsADifference() {
        let diff = SeriesUpdateUndo.diff(recorded: exceptions(kept: [0, 2, 4], detached: [(3, "Own")]),
                                         current: exceptions(kept: [0, 4], detached: [(3, "Own")]))
        XCTAssertEqual(diff.deleted, [slot(2)])
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.edited, [])
        XCTAssertFalse(diff.isEmpty)
        let gone = SeriesUpdateUndo.diff(recorded: exceptions(kept: [0], detached: [(3, "Own")]), current: exceptions(kept: [0]))
        XCTAssertEqual(gone.deleted, [slot(3)], "a detached occurrence deleted since")
    }

    func testAnOccurrenceBackOrNewSinceIsADifference() {
        let diff = SeriesUpdateUndo.diff(recorded: exceptions(kept: [0, 4]), current: exceptions(kept: [0, 2, 4]))
        XCTAssertEqual(diff.added, [slot(2)], "a deleted occurrence that came back")
        XCTAssertFalse(diff.isEmpty)
    }

    func testAnOccurrenceEditedSinceIsADifference() {
        let detachedSince = SeriesUpdateUndo.diff(recorded: exceptions(kept: [0, 2, 4]), current: exceptions(kept: [0, 4], detached: [(2, "New")]))
        XCTAssertEqual(detachedSince.edited, [slot(2)], "edited on its own since")
        XCTAssertEqual(detachedSince.deleted, [])
        let editedAgain = SeriesUpdateUndo.diff(recorded: exceptions(kept: [0], detached: [(3, "Own")]),
                                                current: exceptions(kept: [0], detached: [(3, "Own again")]))
        XCTAssertEqual(editedAgain.edited, [slot(3)], "an edited occurrence edited again")
        let backInSeries = SeriesUpdateUndo.diff(recorded: exceptions(kept: [0], detached: [(3, "Own")]), current: exceptions(kept: [0, 3]))
        XCTAssertEqual(backInSeries.edited, [slot(3)], "a change of state counts too (fail closed)")
    }

    func testOtherWindowsAreADifference() {
        let recorded = exceptions(kept: [0])
        let elsewhere = SeriesExceptions(window: DateInterval(start: window.start.addingTimeInterval(day), duration: 1460 * day),
                                         keptSlots: [slot(0)], detached: [])
        XCTAssertFalse(SeriesUpdateUndo.diff(recorded: recorded, current: elsewhere).isEmpty,
                       "only listings over the recorded windows compare")
    }

    // MARK: - The undo-time refusals

    func testAnUnchangedSeriesIsRestored() {
        let r = record()
        XCTAssertNil(SeriesUpdateUndo.refusal(r, current: current(exceptions: r.after)))
    }

    func testEveryChangeSinceTheUpdateRefuses() {
        let r = record()
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(id: "S/RID=1", exceptions: r.after)), .identity)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(id: nil, exceptions: r.after)), .identity)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(external: "X-other", exceptions: r.after)), .identity)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(isDetached: true, exceptions: r.after)), .identity)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(hasRules: false, rules: [], exceptions: r.after)), .identity)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(rules: snapshot("After", weekly: 4).recurrenceRules, exceptions: r.after)),
                       .ruleChanged)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(iCloud: false, exceptions: r.after)), .notICloud)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(covered: false, exceptions: r.after)), .notCovered)
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(exceptions: nil)), .unlisted)
        let deleted = exceptions(kept: [0, 4], detached: [(3, "Own")])
        XCTAssertEqual(SeriesUpdateUndo.refusal(r, current: current(exceptions: deleted)),
                       .exceptionsChanged(SeriesUpdateUndo.diff(recorded: r.after, current: deleted)))
    }

    /// The undo compares with the state after the update, not before it: a span-all write also
    /// writes into occurrences edited on their own (notes and location, device 2026-11-09).
    func testTheUndoComparesWithTheExceptionsAfterTheUpdate() {
        let before = exceptions(kept: [0, 2, 4], detached: [(3, "Own")])
        let after = exceptions(kept: [0, 2, 4], detached: [(3, "Own, new notes")])
        let r = record(before: before, after: after)
        XCTAssertNil(SeriesUpdateUndo.refusal(r, current: current(exceptions: after)))
        XCTAssertNotNil(SeriesUpdateUndo.refusal(r, current: current(exceptions: before)))
    }

    func testRefusalsKeepTheRecordAndGiveTheWayOn() {
        let r = record()
        let refusals: [SeriesUpdateUndo.Refusal] = [
            .identity, .ruleChanged, .notICloud, .notCovered, .unlisted, .noCalendar,
            .exceptionsChanged(SeriesUpdateUndo.diff(recorded: r.after, current: exceptions(kept: [0], detached: [(3, "Own"), (2, "x")]))),
        ]
        for refusal in refusals {
            let error = SeriesUpdateUndo.refusalError(refusal, title: "Week\u{202E}ly 'x'")
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "\(refusal): kept")
            let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
            XCTAssertTrue(message.hasPrefix("Cannot undo the update of the recurring event 'Weekly \u{2019}x\u{2019}'"), message)
            XCTAssertTrue(message.contains("nothing was written and this history entry was kept"), message)
            XCTAssertTrue(message.contains("To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."), message)
            for tool in ["update_event", "delete_event", "list_events", "move_events_batch"] {
                XCTAssertFalse(message.contains(tool), "\(refusal) names no other tool: \(message)")
            }
        }
        let changed = SeriesUpdateUndo.refusalError(refusals.last!, title: "Weekly").message
        XCTAssertTrue(changed.contains("1 deleted on its own"), changed)
        XCTAssertTrue(changed.contains("1 edited on its own"), changed)
    }

    // MARK: - After the write

    func testTheReadBackMustShowTheStateBeforeTheUpdate() {
        let before = exceptions(kept: [0, 2, 4], detached: [(3, "Own")])
        let r = record(before: before, after: exceptions(kept: [0, 2, 4], detached: [(3, "Own, new notes")]))
        let restored = snapshot("Before", weekly: 5)
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: restored, exceptions: before)), [])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: snapshot("After", weekly: 5), exceptions: before)), ["title"])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: snapshot("Before", weekly: 4), exceptions: before)), ["recurrence"])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: nil, exceptions: before)), ["the series could not be read"])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: restored, exceptions: nil)), ["the occurrences could not be listed"])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: restored, exceptions: exceptions(kept: [0, 1, 2, 4], detached: [(3, "Own")]))),
                       ["1 occurrence deleted before the update came back"])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: restored, exceptions: exceptions(kept: [0, 4], detached: [(3, "Own")]))),
                       ["1 occurrence is missing"])
        XCTAssertEqual(SeriesUpdateUndo.readBackMismatch(r, readBack: .init(series: restored, exceptions: r.after)),
                       ["1 occurrence edited on its own differs from before the update"])
    }

    func testAMismatchAfterTheWriteIsReportedAndNeverCalledDone() {
        let error = SeriesUpdateUndo.readBackError(record(fields: ["title", "notes"]), mismatch: ["title", "1 occurrence is missing"])
        XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
        XCTAssertFalse(message.hasPrefix("Undone"), message)
        XCTAssertTrue(message.contains("Undo wrote the previous title and notes to the whole recurring event 'After'"), message)
        XCTAssertTrue(message.contains("title; 1 occurrence is missing"), message)
        XCTAssertTrue(message.contains("check it in Calendar"), message)
    }

    func testTheUndoneTextNamesTheRestoredFields() {
        XCTAssertEqual(SeriesUpdateUndo.undoneMessage(record(fields: ["title", "notes", "location"])),
                       "Undone: restored the title, notes and location of the whole recurring event 'Before' to their values before the update; its occurrences edited or deleted on their own within a year of the series' dates were listed before and after the write and are as they were before the update")
        XCTAssertTrue(SeriesUpdateUndo.undoneMessage(record(fields: ["notes"])).hasPrefix("Undone: restored the notes of the whole recurring event"))
    }

    // MARK: - The record

    func testTheRecordIsListedAndRedoWritesNothing() {
        let op = UndoOperation.updateSeries(record(fields: ["title", "location"]))
        XCTAssertEqual(op.description, "Updated recurring event: Before (whole series; undo restores its title and location)")
        XCTAssertEqual(op.redoInstruction,
                       "Cannot redo the update of recurring event 'Before': redo does not apply updates again, so it stays as the undo left it. Use update_event with span 'all' to apply the changes again. Nothing was written.")
        XCTAssertFalse(op.redoWrites)
        XCTAssertNil(op.redoPostState)
        guard case .event(let id, _, let state, let restoring)? = op.undoPostState else { return XCTFail("\(String(describing: op.undoPostState))") }
        XCTAssertEqual(id, "S")
        XCTAssertEqual(state.title, "After", "the #236 guard compares with the state the update left")
        XCTAssertEqual(restoring?.title, "Before")
        XCTAssertNil(op.recurringTargetRefusal(hasRecurrenceRules: true, isDetached: false), "the one record that writes to a series")
        XCTAssertNil(op.batchMemberUndoRefusal)
        XCTAssertNil(op.updateRefusalNote(changedElsewhere: ["location"]), "no keep_later_edits note (verify r1)")
        XCTAssertEqual(op.replacingEventIdentifier("S", with: "T").undoPostState?.itemID, "T", "#435")
    }
}
