import EventKit
import XCTest
@testable import CheICalMCP

/// #429: a rollover lowers a count-bounded rule's `occurrenceCount` by one and changes nothing else
/// (measured on iCloud, 2026-11-05: weekly, daily, monthly, date-only, several weekdays, overdue).
/// `evaluate` accepts exactly that change and no other. In-memory EventKit objects only.
final class ReminderCountRolloverTests: XCTestCase {
    private func rule(count: Int? = nil, interval: Int = 1, frequency: EKRecurrenceFrequency = .weekly) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: count.map { EKRecurrenceEnd(occurrenceCount: $0) })
    }

    private func snap(day: Int, rules: [EKRecurrenceRule], completed: Bool = false) -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(id: "r", title: "Repeat", calendarID: "list", sourceID: "source", isCompleted: completed,
                                   hasRecurrence: true, due: ReminderDueValue(components: DateComponents(year: 2026, month: 12, day: day)),
                                   rules: rules.map(ReminderRecurrenceRuleValue.init(from:)), completionDate: nil)
    }

    private func evaluate(_ before: [EKRecurrenceRule], _ after: [EKRecurrenceRule]) -> ReminderNextOccurrence {
        .evaluate(before: snap(day: 10, rules: before), observed: snap(day: 17, rules: after), requestedCompleted: true)
    }

    func testACountOneLowerIsTheRollover() {
        for (before, after) in [(3, 2), (2, 1), (500, 499)] {
            let next = evaluate([rule(count: before)], [rule(count: after)])
            XCTAssertEqual(next.status, .confirmed, "\(before) -> \(after)")
            XCTAssertNil(next.reason)
            XCTAssertEqual(next.reminder?.rules?.first?.occurrenceCount, after, "reports what the store holds")
        }
    }

    /// A store that keeps the count, as `evaluate` accepted before #429.
    func testAnUnchangedCountStaysConfirmed() {
        XCTAssertEqual(evaluate([rule(count: 3)], [rule(count: 3)]).status, .confirmed)
        XCTAssertEqual(evaluate([rule()], [rule()]).status, .confirmed)
    }

    func testAnyOtherCountChangeIsNotTheRollover() {
        let changes: [(String, [EKRecurrenceRule], [EKRecurrenceRule])] = [
            ("dropped by two", [rule(count: 3)], [rule(count: 1)]),
            ("rose", [rule(count: 2)], [rule(count: 3)]),
            ("appeared", [rule()], [rule(count: 2)]),
            ("disappeared", [rule(count: 2)], [rule()])
        ]
        for (name, before, after) in changes {
            let next = evaluate(before, after)
            XCTAssertEqual(next.status, .unknown, name)
            XCTAssertEqual(next.reason, "recurrence_unverified", name)
        }
    }

    func testAnotherChangedFieldNextToTheCountIsNotTheRollover() {
        let changes: [(String, EKRecurrenceRule)] = [
            ("interval", rule(count: 2, interval: 2)),
            ("frequency", rule(count: 2, frequency: .daily))
        ]
        for (name, after) in changes {
            XCTAssertEqual(evaluate([rule(count: 3)], [after]).reason, "recurrence_unverified", name)
        }
    }

    func testADifferentNumberOfRulesIsNotTheRollover() {
        XCTAssertEqual(evaluate([rule(count: 3)], []).reason, "recurrence_unverified")
        XCTAssertEqual(evaluate([rule(count: 3)], [rule(count: 2), rule(count: 2)]).reason, "recurrence_unverified")
        XCTAssertEqual(evaluate([rule(count: 3), rule()], [rule(count: 2)]).reason, "recurrence_unverified")
    }

    /// The later guards still run: the count alone does not confirm a rollover.
    func testTheDueMustStillAdvance() {
        let next = ReminderNextOccurrence.evaluate(before: snap(day: 10, rules: [rule(count: 3)]),
                                                   observed: snap(day: 10, rules: [rule(count: 2)]), requestedCompleted: true)
        XCTAssertEqual(next.reason, "due_not_advanced")
    }

    /// The last occurrence: completed in place, no successor, the count stays at 1 (measured).
    func testTheLastOccurrenceHasNoSuccessor() {
        let last = snap(day: 24, rules: [rule(count: 1)])
        let next = ReminderNextOccurrence.evaluate(before: last, observed: snap(day: 24, rules: [rule(count: 1)], completed: true),
                                                   requestedCompleted: true)
        XCTAssertEqual(next.status, .unknown)
        XCTAssertEqual(next.reason, "successor_not_observed")
    }

    /// #423 on a count-bounded reminder: the re-read holds the lowered count, so it matches the
    /// confirmed occurrence and the alarms are reported.
    func testTheRolloverAlarmsAreReported() throws {
        let item = EKReminder(eventStore: SharedTestStore.store)
        item.addAlarm(EKAlarm(relativeOffset: -900))
        item.addAlarm(EKAlarm(relativeOffset: 0))
        let next = evaluate([rule(count: 3)], [rule(count: 2)])
        let observed = try XCTUnwrap(ReminderRolloverAlarms.observe(before: [15], next: next, item: item, reload: {
            self.snap(day: 17, rules: [self.rule(count: 2)])
        }))
        XCTAssertTrue(observed.readBack)
        XCTAssertEqual(observed.minutesBefore, [15, 0])
        XCTAssertEqual(observed.added, [0])
    }

    /// Another completion between the save and the re-read lowers the count again: not the
    /// occurrence the response names, so its alarms are not claimed.
    func testALowerCountOnTheReReadClaimsNothing() throws {
        let next = evaluate([rule(count: 3)], [rule(count: 2)])
        let observed = try XCTUnwrap(ReminderRolloverAlarms.observe(before: [15], next: next, item: EKReminder(eventStore: SharedTestStore.store), reload: {
            self.snap(day: 17, rules: [self.rule(count: 1)])
        }))
        XCTAssertFalse(observed.readBack)
    }

    /// `matchesOccurrence` stays strict: it is the identity the #204 undo guard and #423's re-read use.
    func testOccurrenceIdentityStillComparesTheCount() {
        let saved = snap(day: 17, rules: [rule(count: 2)])
        XCTAssertFalse(saved.matchesOccurrence(snap(day: 17, rules: [rule(count: 3)])))
        XCTAssertFalse(saved.matchesOccurrence(snap(day: 17, rules: [rule(count: 1)])))
        XCTAssertTrue(saved.matchesOccurrence(snap(day: 17, rules: [rule(count: 2)])))
    }
}
