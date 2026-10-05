import EventKit
import XCTest
@testable import CheICalMCP

final class EventCopyOperationTests: XCTestCase {
    enum Failure: Error { case save, remove }
    private func snapshot() -> EventSnapshot {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Source"
        event.startDate = Date(timeIntervalSince1970: 100)
        event.endDate = Date(timeIntervalSince1970: 200)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        return EventSnapshot(from: event, includeRecurrence: false)
    }
    func testRestoreUsesExactCalendarIdentityAndRejectsMissingSource() throws {
        let saved = snapshot()
        let calendars = [(id: "other-account", title: "Work"), (id: saved.calendarIdentifier, title: "Work")]
        let selected = try saved.resolveCalendar(in: calendars, identifier: { $0.id })
        XCTAssertEqual(selected.id, saved.calendarIdentifier)
        XCTAssertThrowsError(try saved.resolveCalendar(in: [calendars[0]], identifier: { $0.id }))
    }

    func testMoveReturnsSourceUndoOnlyAfterSuccessfulDeletion() throws {
        var calls: [String] = []
        let outcome = try EventCopyOperation.execute(source: snapshot(), saveCopy: { calls.append("save"); return "new" }, removeSource: { calls.append("remove") })
        XCTAssertEqual(calls, ["save", "remove"])
        XCTAssertEqual(outcome.value, "new")
        guard case .deleteEvent(let saved)? = outcome.undo else { return XCTFail("Missing deletion undo") }
        XCTAssertEqual(saved.title, "Source")
        XCTAssertNil(saved.recurrenceRules, "a single removed occurrence must not restore a duplicate series")
    }
    func testCopyDoesNotDeleteOrRecordSourceUndo() throws {
        let outcome = try EventCopyOperation.execute(source: nil, saveCopy: { "new" }, removeSource: { XCTFail("must not remove") })
        XCTAssertNil(outcome.undo)
    }
    func testFailedSaveDoesNotDeleteSource() {
        XCTAssertThrowsError(try EventCopyOperation.execute(source: snapshot(), saveCopy: { () throws -> String in throw Failure.save }, removeSource: { XCTFail("must not remove") }))
    }
    func testFailedDeletionDoesNotProduceUndoOutcome() {
        XCTAssertThrowsError(try EventCopyOperation.execute(source: snapshot(), saveCopy: { "new" }, removeSource: { throw Failure.remove }))
    }

    // MARK: - time-only retry (#253 verify #2)

    enum SaveFailure: Error { case first, retry }
    private let absoluteDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every kind a calendar outside iCloud might refuse: a location alarm, an email alarm,
    /// a sound; plus time-only alarms, which every calendar accepts.
    private func alarms() -> [AlarmSnapshot] {
        let place = EKStructuredLocation(title: "Office")
        let location = EKAlarm()
        location.structuredLocation = place
        location.proximity = .enter
        let email = EKAlarm(relativeOffset: -3600)
        email.emailAddress = "owner@example.com"
        let sound = EKAlarm(relativeOffset: -7200)
        sound.soundName = "Ping"
        return [EKAlarm(absoluteDate: absoluteDate), EKAlarm(relativeOffset: -900), location, email, sound]
            .map(AlarmSnapshot.init(from:))
    }

    private var timeOnly: [AlarmSnapshot] {
        [EKAlarm(absoluteDate: absoluteDate), EKAlarm(relativeOffset: -900), EKAlarm(relativeOffset: 0),
         EKAlarm(relativeOffset: -3600), EKAlarm(relativeOffset: -7200)].map(AlarmSnapshot.init(from:))
    }

    func testASavedCopyDropsNothing() throws {
        var attempts: [[AlarmSnapshot]] = []
        let saved = try EventCopyOperation.saveCopy(alarms: alarms()) { attempt in attempts.append(attempt); return "copy" }

        XCTAssertEqual(saved.value, "copy")
        XCTAssertEqual(saved.notCarriedOver, [])
        XCTAssertEqual(attempts, [alarms()])
    }

    /// A target that refuses the alarms used to make copy_event and the move fallback fail
    /// where the copy (with time-only alarms) used to succeed.
    func testARefusedCopyIsSavedAgainWithTimeOnlyAlarmsAndSaysWhatWasDropped() throws {
        var attempts: [[AlarmSnapshot]] = []
        var refused: [Error] = []
        let saved = try EventCopyOperation.saveCopy(alarms: alarms(), onRetry: { refused.append($0) }) { attempt -> String in
            attempts.append(attempt)
            if attempts.count == 1 { throw SaveFailure.first }
            return "copy"
        }

        XCTAssertEqual(saved.value, "copy")
        XCTAssertEqual(refused.map { $0 as? SaveFailure }, [.first], "the refused save is logged, not swallowed")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(Set(attempts[1]), Set(timeOnly))
        XCTAssertEqual(saved.notCarriedOver, ["location_alarms", "email_alarms", "alarm_sounds"])
    }

    /// Without such alarms the failure is not about alarms: it surfaces as before, no retry.
    func testAFailureWithTimeOnlyAlarmsSurfacesWithoutARetry() {
        var attempts = 0
        XCTAssertThrowsError(try EventCopyOperation.saveCopy(alarms: timeOnly) { _ -> String in
            attempts += 1
            throw SaveFailure.first
        }) { error in
            XCTAssertEqual(error as? SaveFailure, .first)
        }
        XCTAssertEqual(attempts, 1)
    }

    /// The retry is the copy as it was saved before #230, so its error is the one a copy
    /// would have reported then.
    func testAFailedRetrySurfacesItsError() {
        var attempts = 0
        XCTAssertThrowsError(try EventCopyOperation.saveCopy(alarms: alarms()) { _ -> String in
            attempts += 1
            throw attempts == 1 ? SaveFailure.first : SaveFailure.retry
        }) { error in
            XCTAssertEqual(error as? SaveFailure, .retry)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testOnlyTheKindsPresentAreReported() throws {
        let sound = EKAlarm(relativeOffset: -60)
        sound.soundName = "Ping"
        var attempts = 0
        let saved = try EventCopyOperation.saveCopy(alarms: [AlarmSnapshot(from: sound)]) { _ -> String in
            attempts += 1
            if attempts == 1 { throw SaveFailure.first }
            return "copy"
        }
        XCTAssertEqual(saved.notCarriedOver, ["alarm_sounds"])
    }
}
