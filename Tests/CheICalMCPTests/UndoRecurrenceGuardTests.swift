import EventKit
import XCTest
@testable import CheICalMCP

/// #236, PR #259 verify #2 / #6 / #11: how the post-state guard compares recurrence. Whether
/// rules count is decided by what the undo writes (the restored snapshot, or the whole item for
/// a delete), with no rules and `nil` the same; the rules themselves compare as sets, with the
/// end to the second (to the day for an all-day event). In memory only, so no TCC prompt.
final class UndoRecurrenceGuardTests: XCTestCase {
    private let store = EKEventStore()
    private lazy var calendar = EKCalendar(for: .event, eventStore: store)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(rules: [EKRecurrenceRule]?) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "Standup"
        event.startDate = start
        event.endDate = start.addingTimeInterval(1800)
        event.recurrenceRules = rules
        return event
    }

    private func weekly(_ days: [EKWeekday], end: EKRecurrenceEnd? = nil) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days.map { EKRecurrenceDayOfWeek($0) },
                         daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                         setPositions: nil, end: end)
    }

    private func snapshot(_ rule: EKRecurrenceRule) -> RecurrenceRuleSnapshot { RecurrenceRuleSnapshot(from: rule) }

    private var daily: EKRecurrenceRule { EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil) }

    // MARK: - Which rules count (verify #2 / #6)

    /// update_event with clear_recurrence, then a rule added in Calendar.app: the undo would
    /// write the old rule over it. A store may report a one-off's rules as nil (emulated with
    /// `includeRecurrence: false`) or as none.
    func testClearRecurrenceUndoRefusesWhenARuleWasAddedElsewhere() {
        for reportsNil in [true, false] {
            let event = makeEvent(rules: [weekly([.monday])])
            let old = EventSnapshot(from: event)
            event.recurrenceRules = nil                                       // the update
            let saved = EventSnapshot(from: event, includeRecurrence: !reportsNil)
            event.recurrenceRules = [daily]                                   // added elsewhere

            XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: old), ["recurrence"],
                           "rules reported as \(reportsNil ? "nil" : "none")")
        }
    }

    /// Create-undo of a one-off deletes the whole series it has since become.
    func testCreateUndoRefusesWhenAOneOffGainedRecurrence() {
        for reportsNil in [true, false] {
            let event = makeEvent(rules: nil)
            let saved = EventSnapshot(from: event, includeRecurrence: !reportsNil)
            event.recurrenceRules = [daily]

            XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), ["recurrence"],
                           "rules reported as \(reportsNil ? "nil" : "none")")
        }
    }

    /// `applySnapshot` leaves the rules alone when the restored snapshot recorded none
    /// (`includeRecurrence: false`), so update-undo does not compare them then.
    func testUpdateUndoComparesRecurrenceOnlyWhenTheRestoredSnapshotRecordedRules() {
        let restored = EventSnapshot(from: makeEvent(rules: [weekly([.monday])]), includeRecurrence: false)
        let event = makeEvent(rules: [weekly([.monday])])
        let saved = EventSnapshot(from: event)
        event.recurrenceRules = [daily]

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: restored), [])
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), ["recurrence"])
    }

    // MARK: - How rules compare (verify #11)

    func testDaysOfTheWeekCompareAsASet() {
        let mondayWednesday = snapshot(weekly([.monday, .wednesday]))
        let wednesdayMonday = snapshot(weekly([.wednesday, .monday]))

        XCTAssertTrue(RecurrenceRuleSnapshot.sameRules([mondayWednesday], [wednesdayMonday], allDay: false))
        XCTAssertFalse(RecurrenceRuleSnapshot.sameRules([mondayWednesday], [snapshot(weekly([.monday]))], allDay: false))
    }

    func testRuleListsCompareAsAMultiset() {
        let a = snapshot(weekly([.monday]))
        let b = snapshot(daily)

        XCTAssertTrue(RecurrenceRuleSnapshot.sameRules([a, b], [b, a], allDay: false))
        XCTAssertFalse(RecurrenceRuleSnapshot.sameRules([a, a], [a, b], allDay: false))
    }

    func testNoRulesAndNilAreTheSame() {
        XCTAssertTrue(RecurrenceRuleSnapshot.sameRules(nil, [], allDay: false))
        XCTAssertFalse(RecurrenceRuleSnapshot.sameRules(nil, [snapshot(daily)], allDay: false))
    }

    func testRecurrenceEndComparesToTheSecond() {
        let end = start.addingTimeInterval(30 * 86_400)
        let recorded = snapshot(weekly([.monday], end: EKRecurrenceEnd(end: end)))

        XCTAssertTrue(RecurrenceRuleSnapshot.sameRules([recorded], [snapshot(weekly([.monday], end: EKRecurrenceEnd(end: end.addingTimeInterval(0.5))))], allDay: false))
        XCTAssertFalse(RecurrenceRuleSnapshot.sameRules([recorded], [snapshot(weekly([.monday], end: EKRecurrenceEnd(end: end.addingTimeInterval(60))))], allDay: false))
    }

    /// CalDAV can store an all-day series' end as a date, which reads back as midnight.
    func testAllDayRecurrenceEndComparesByDay() {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let lateOnThatDay = snapshot(weekly([.monday], end: EKRecurrenceEnd(end: day.addingTimeInterval(86_399))))
        let midnight = snapshot(weekly([.monday], end: EKRecurrenceEnd(end: day)))

        XCTAssertTrue(RecurrenceRuleSnapshot.sameRules([lateOnThatDay], [midnight], allDay: true))
        XCTAssertFalse(RecurrenceRuleSnapshot.sameRules([lateOnThatDay], [midnight], allDay: false))
    }

    /// The order a store returns BYDAY in does not turn into a refusal through the event check.
    func testReorderedDaysAreNotAChangeForTheEventCheck() {
        let event = makeEvent(rules: [weekly([.monday, .wednesday])])
        let saved = EventSnapshot(from: event)
        event.recurrenceRules = [weekly([.wednesday, .monday])]

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
    }
}
