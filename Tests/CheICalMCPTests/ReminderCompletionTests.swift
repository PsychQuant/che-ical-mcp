import EventKit
import XCTest
@testable import CheICalMCP

final class ReminderCompletionTests: XCTestCase {
    private func snapshot(
        id: String = "reminder", calendar: String = "calendar", source: String = "source",
        completed: Bool = false, recurring: Bool = true, day: Int? = 5,
        hour: Int? = nil, zone: String? = nil, interval: Int = 1
    ) -> ReminderCompletionSnapshot {
        var components: DateComponents?
        if let day {
            components = DateComponents(year: 2026, month: 9, day: day, hour: hour)
            components?.timeZone = zone.flatMap(TimeZone.init(identifier:))
        }
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: interval, end: nil)
        return ReminderCompletionSnapshot(
            id: id, title: "Task", calendarID: calendar, sourceID: source,
            isCompleted: completed, hasRecurrence: recurring,
            due: ReminderDueValue(components: components),
            rules: recurring ? [ReminderRecurrenceRuleValue(from: rule)] : [],
            completionDate: completed ? Date(timeIntervalSince1970: 1_756_900_000) : nil
        )
    }

    func testObservedDateOnlySuccessorIsConfirmed() {
        let next = ReminderNextOccurrence.evaluate(
            before: snapshot(), observed: snapshot(day: 6), requestedCompleted: true)
        XCTAssertEqual(next.status, "confirmed")
        XCTAssertEqual(next.reminder?.due, snapshot(day: 6).due)
    }

    func testPastDueSuccessorCanStillBeConfirmed() {
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(day: 1), observed: snapshot(day: 2),
            requestedCompleted: true).status, "confirmed")
    }

    func testNoObservationIsUnknown() {
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(), observed: nil, requestedCompleted: true).status, "unknown")
    }

    func testUnchangedAndEarlierDueDatesAreUnknown() {
        for day in [4, 5] {
            XCTAssertEqual(ReminderNextOccurrence.evaluate(
                before: snapshot(), observed: snapshot(day: day),
                requestedCompleted: true).status, "unknown")
        }
    }

    func testOtherIDsCalendarsSourcesOrRulesAreNeverInferredAsSuccessors() {
        for observed in [snapshot(id: "other", day: 6), snapshot(calendar: "other", day: 6),
                         snapshot(source: "other", day: 6), snapshot(day: 6, interval: 2)] {
            XCTAssertEqual(ReminderNextOccurrence.evaluate(
                before: snapshot(), observed: observed, requestedCompleted: true).status, "unknown")
        }
    }

    func testCompletedObservationAndMissingDueAreUnknown() {
        for observed in [snapshot(completed: true, day: 6), snapshot(day: nil)] {
            XCTAssertEqual(ReminderNextOccurrence.evaluate(
                before: snapshot(), observed: observed, requestedCompleted: true).status, "unknown")
        }
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(day: nil), observed: snapshot(day: 6),
            requestedCompleted: true).status, "unknown")
    }

    func testPrecisionAndTimeZoneChangesAreNotConfirmed() {
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(), observed: snapshot(day: 6, hour: 9),
            requestedCompleted: true).status, "unknown")
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(hour: 9, zone: "Asia/Tokyo"),
            observed: snapshot(day: 6, hour: 9, zone: "Europe/London"),
            requestedCompleted: true).status, "unknown")
    }

    func testOneTimeReopenAndAlreadyCompletedDoNotResolveSuccessors() {
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(recurring: false), observed: nil,
            requestedCompleted: true).status, "not_applicable")
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(completed: true), observed: nil,
            requestedCompleted: false).status, "not_applicable")
        XCTAssertEqual(ReminderNextOccurrence.evaluate(
            before: snapshot(completed: true), observed: nil,
            requestedCompleted: true).status, "not_applicable")
    }

    func testCompletionResponseSeparatesSuccessfulOperationFromIncompleteSavedState() throws {
        let before = snapshot()
        let after = snapshot(day: 6)
        let result = ReminderCompletionResult(before: before, afterSave: after,
            requestedCompleted: true, nextOccurrence: .evaluate(
                before: before, observed: after, requestedCompleted: true))
        let dictionary = result.dictionary
        XCTAssertEqual(dictionary["action"] as? String, "completed")
        XCTAssertEqual(dictionary["is_completed"] as? Bool, false)
        let operation = try XCTUnwrap(dictionary["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "complete")
        XCTAssertEqual(operation["status"] as? String, "succeeded")
        XCTAssertEqual(operation["requested_completed"] as? Bool, true)
        let target = try XCTUnwrap(operation["target"] as? [String: Any])
        XCTAssertEqual(target["id"] as? String, before.id)
        XCTAssertEqual(target["was_completed"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(dictionary))
    }

    func testReopenPreservesLegacyActionAndReportsNewOperationType() throws {
        let result = ReminderCompletionResult(before: snapshot(completed: true),
            afterSave: snapshot(), requestedCompleted: false, nextOccurrence: .notApplicable)
        XCTAssertEqual(result.dictionary["action"] as? String, "completed")
        XCTAssertEqual((result.dictionary["operation"] as? [String: Any])?["type"] as? String, "reopen")
    }

    func testUnknownFollowupDoesNotTurnSuccessfulWriteIntoFailure() {
        let result = ReminderCompletionResult(before: snapshot(), afterSave: snapshot(completed: true),
            requestedCompleted: true, nextOccurrence: .unknown(reason: "observation_unavailable"))
        XCTAssertEqual((result.dictionary["operation"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertEqual((result.dictionary["next_occurrence"] as? [String: Any])?["status"] as? String, "unknown")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result.dictionary))
    }

    func testAbsentSuccessorUsesExplicitNullReminder() throws {
        for next in [ReminderNextOccurrence.notApplicable, .unknown(reason: "observation_unavailable")] {
            XCTAssertTrue(next.dictionary["reminder"] is NSNull)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(next.dictionary))
        }
    }

    func testConfirmedSuccessorIncludesActualReminderDue() throws {
        let observed = snapshot(day: 6)
        let next = ReminderNextOccurrence.evaluate(
            before: snapshot(), observed: observed, requestedCompleted: true)
        let reminder = try XCTUnwrap(next.dictionary["reminder"] as? [String: Any])
        XCTAssertEqual(reminder["id"] as? String, observed.id)
        XCTAssertEqual(reminder["is_completed"] as? Bool, false)
        let due = try XCTUnwrap(reminder["due"] as? [String: Any])
        XCTAssertEqual(due["date"] as? String, "2026-09-06")
        XCTAssertTrue(due["date_time"] is NSNull)
    }

    func testConfirmedMessageIncludesObservedNextDue() throws {
        // #194 asks for "completed; next occurrence <date>": the human-readable
        // message must carry the observed successor's due, not just the JSON.
        let before = snapshot()
        let after = snapshot(day: 6)
        let result = ReminderCompletionResult(before: before, afterSave: after,
            requestedCompleted: true, nextOccurrence: .evaluate(
                before: before, observed: after, requestedCompleted: true))
        let message = try XCTUnwrap(result.dictionary["message"] as? String)
        XCTAssertTrue(message.contains("2026-09-06"), message)
    }

    func testConfirmedMessageRendersZonedDueInItsOwnTimeZone() throws {
        // A UTC instant can name a different calendar day than the one the user
        // set (07:00 Asia/Taipei is the previous day in UTC); the prose must use
        // the reminder's own wall clock and zone.
        let before = snapshot(hour: 7, zone: "Asia/Taipei")
        let after = snapshot(day: 6, hour: 7, zone: "Asia/Taipei")
        let result = ReminderCompletionResult(before: before, afterSave: after,
            requestedCompleted: true, nextOccurrence: .evaluate(
                before: before, observed: after, requestedCompleted: true))
        let message = try XCTUnwrap(result.dictionary["message"] as? String)
        XCTAssertTrue(message.contains("2026-09-06 07:00:00 Asia/Taipei"), message)
        XCTAssertFalse(message.contains("2026-09-05"), message)
    }

    func testUnknownResultStillReportsObservedSavedState() throws {
        // The saved object is captured in full; `unknown` must not throw it away.
        let before = snapshot()
        let after = snapshot(completed: true)
        let result = ReminderCompletionResult(before: before, afterSave: after,
            requestedCompleted: true, nextOccurrence: .evaluate(
                before: before, observed: after, requestedCompleted: true))
        let dictionary = result.dictionary
        XCTAssertEqual((dictionary["next_occurrence"] as? [String: Any])?["status"] as? String, "unknown")
        let observed = try XCTUnwrap(dictionary["observed"] as? [String: Any])
        XCTAssertEqual(observed["id"] as? String, "reminder")
        XCTAssertEqual(observed["is_completed"] as? Bool, true)
        XCTAssertEqual(observed["has_recurrence"] as? Bool, true)
        XCTAssertEqual((observed["due"] as? [String: Any])?["date"] as? String, "2026-09-05")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(dictionary))
    }

    // MARK: - occurrence identity (recurring undo guard)

    func testMatchesOccurrenceIsReflexiveForIdentifiableSnapshots() {
        // An identity predicate that is false for x == x jams the undo stack on
        // items that never changed (verify round 1, rows 1 / 18).
        let recurring = snapshot()
        XCTAssertTrue(recurring.isIdentifiable)
        XCTAssertTrue(recurring.matchesOccurrence(recurring))
        let oneOff = snapshot(recurring: false, day: nil)
        XCTAssertTrue(oneOff.isIdentifiable)
        XCTAssertTrue(oneOff.matchesOccurrence(oneOff))
    }

    func testOccurrenceGuardAllowsCompletionChangeButRejectsRollover() {
        XCTAssertTrue(snapshot().matchesOccurrence(snapshot(completed: true)))
        XCTAssertFalse(snapshot().matchesOccurrence(snapshot(day: 6)))
        XCTAssertFalse(snapshot().matchesOccurrence(snapshot(interval: 2)))
        XCTAssertFalse(snapshot().matchesOccurrence(snapshot(calendar: "other")))
        XCTAssertFalse(snapshot().matchesOccurrence(snapshot(source: "other")))
        XCTAssertFalse(snapshot().matchesOccurrence(snapshot(id: "other")))
    }

    func testRecurringSnapshotWithoutDueOrRulesIsNotIdentifiable() {
        XCTAssertFalse(snapshot(day: nil).isIdentifiable)
        // Identity is value equality, not orderability: a due that has no
        // chronological instant (DST fold, invalid day) is still comparable.
        XCTAssertTrue(snapshot(day: 32).isIdentifiable)
        XCTAssertTrue(snapshot(day: 32).matchesOccurrence(snapshot(day: 32)))
        let noRules = ReminderCompletionSnapshot(
            id: "r", title: "t", calendarID: "c", sourceID: "s", isCompleted: false,
            hasRecurrence: true, due: snapshot().due, rules: nil, completionDate: nil)
        XCTAssertFalse(noRules.isIdentifiable)
        let emptyRules = ReminderCompletionSnapshot(
            id: "r", title: "t", calendarID: "c", sourceID: "s", isCompleted: false,
            hasRecurrence: true, due: snapshot().due, rules: [], completionDate: nil)
        XCTAssertFalse(emptyRules.isIdentifiable)
        XCTAssertFalse(snapshot(day: nil).matchesOccurrence(snapshot(day: nil)))
    }
}
