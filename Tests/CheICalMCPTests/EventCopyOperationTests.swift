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

    // MARK: - refused copy (#253 verify round 2, D1)

    enum SaveFailure: Error { case refused }

    /// Every kind a calendar outside iCloud might refuse (a location alarm, an email alarm, a
    /// sound), plus time-only alarms, which every calendar accepts.
    private func alarms() -> [AlarmSnapshot] {
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Office")
        location.proximity = .enter
        let email = EKAlarm(relativeOffset: -3600)
        email.emailAddress = "owner@example.com"
        let sound = EKAlarm(relativeOffset: -7200)
        sound.soundName = "Ping"
        return [EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)), EKAlarm(relativeOffset: -900),
                location, email, sound].map(AlarmSnapshot.init(from:))
    }

    private var timeOnly: [AlarmSnapshot] {
        [EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)), EKAlarm(relativeOffset: -900)]
            .map(AlarmSnapshot.init(from:))
    }

    func testASavedCopyIsSavedOnce() throws {
        var attempts = 0
        let value = try EventCopyOperation.saveCopy(carrying: alarms(), logFailure: { _ in XCTFail("nothing to log"); return "" }) {
            attempts += 1
            return "copy"
        }
        XCTAssertEqual(value, "copy")
        XCTAssertEqual(attempts, 1)
    }

    /// Round 1 retried a refused copy with time-only alarms; the retry could not undo the
    /// refused copy and fired on any error. Now the copy fails, as it did before that retry,
    /// and the error names the alarms some calendars refuse so the caller can decide. The
    /// underlying error goes to the log, and its code into the message.
    func testARefusedCopyFailsOnceAndNamesItsLocationEmailAndSoundAlarms() {
        var attempts = 0
        var logged: [Error] = []
        XCTAssertThrowsError(try EventCopyOperation.saveCopy(carrying: alarms(),
                                                             logFailure: { logged.append($0); return "eventkit_error_1" }) { () throws -> String in
            attempts += 1
            throw SaveFailure.refused
        }) { error in
            guard case .copyRefused(let code, let kinds)? = error as? EventKitError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "eventkit_error_1")
            XCTAssertEqual(kinds, ["location_alarms", "email_alarms", "alarm_sounds"])
        }
        XCTAssertEqual(attempts, 1, "a refused copy is not saved again")
        XCTAssertEqual(logged.map { $0 as? SaveFailure }, [.refused])
    }

    /// Without such alarms there is nothing to name: the error surfaces unchanged.
    func testAFailureWithTimeOnlyAlarmsSurfacesUnchanged() {
        XCTAssertThrowsError(try EventCopyOperation.saveCopy(carrying: timeOnly,
                                                             logFailure: { _ in XCTFail("logged by the caller as before"); return "" }) { () throws -> String in
            throw SaveFailure.refused
        }) { error in
            XCTAssertEqual(error as? SaveFailure, .refused)
        }
    }

    func testOnlyTheKindsPresentAreNamed() {
        let sound = EKAlarm(relativeOffset: -60)
        sound.soundName = "Ping"
        XCTAssertThrowsError(try EventCopyOperation.saveCopy(carrying: [AlarmSnapshot(from: sound)],
                                                             logFailure: { _ in "eventkit_error_1" }) { () throws -> String in
            throw SaveFailure.refused
        }) { error in
            guard case .copyRefused(_, let kinds)? = error as? EventKitError else { return XCTFail("\(error)") }
            XCTAssertEqual(kinds, ["alarm_sounds"])
        }
    }

    func testTheRefusalMessageGivesTheCodeAndTheAlarmKinds() {
        let message = EventKitError.copyRefused(code: "eventkit_error_1", alarmKinds: ["location_alarms", "alarm_sounds"])
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("eventkit_error_1"), message)
        XCTAssertTrue(message.contains("location_alarms, alarm_sounds"), message)
    }

    /// Verify round 3: the error is raised for any failed save of such a copy (a network or
    /// iCloud error too), so it names the alarms as a possible cause only, claims no more than
    /// that the original was not removed, and tells the caller to do nothing: a caller that
    /// followed "remove those alarms" would delete the user's alarms after an unrelated error.
    func testTheRefusalMessageIsDeclarative() {
        let message = EventKitError.copyRefused(code: "eventkit_error_1", alarmKinds: ["email_alarms"])
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("possible cause"), message)
        XCTAssertTrue(message.contains("original event was not removed"), message)
        for imperative in ["Remove ", "remove those", "try again", "choose another", "unchanged"] {
            XCTAssertFalse(message.contains(imperative), "\(imperative): \(message)")
        }
    }
}
