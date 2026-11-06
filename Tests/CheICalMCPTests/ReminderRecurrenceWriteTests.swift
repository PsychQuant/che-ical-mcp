import EventKit
import XCTest
@testable import CheICalMCP

/// #354: `update_reminder` changes or removes a reminder's recurrence rule. Device (2026-11-05,
/// iCloud): a weekday change keeps the due date and the identifier, the pending occurrence stays on
/// its day and the series continues on the new days after it is completed; clearing keeps the due;
/// `clear_due_date` on a repeating reminder fails at the save (EKErrorDomain 18). In-memory
/// EventKit objects only.
final class ReminderRecurrenceWriteTests: XCTestCase {
    private let thursdayDue = DateComponents(year: 2026, month: 12, day: 10, hour: 9, minute: 0)

    private func weekly(_ days: [Int]) -> RecurrenceRuleInput {
        RecurrenceRuleInput(frequency: .weekly, interval: 1, endDate: nil, occurrenceCount: nil,
                            daysOfWeek: days, daysOfMonth: nil, excludedOccurrenceDates: nil)
    }

    private func repeatingReminder(days: [Int] = [5]) -> EKReminder {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.title = "weekly"
        reminder.dueDateComponents = thursdayDue
        reminder.recurrenceRules = [EventKitManager.makeRecurrenceRule(from: weekly(days))]
        return reminder
    }

    private func apply(_ request: ReminderUpdateRequest, to reminder: EKReminder, saved: inout Bool) throws {
        var didSave = false
        defer { saved = didSave }
        _ = try ReminderUpdateWrite.apply(request, to: reminder, calendar: nil,
                                          save: { didSave = true }, reload: { true }, rollback: {})
    }

    func testTheRuleIsReplacedAndTheDueStays() throws {
        let reminder = repeatingReminder()
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([6])), to: reminder, saved: &saved)
        XCTAssertTrue(saved)
        XCTAssertEqual(reminder.recurrenceRules?.count, 1)
        XCTAssertEqual(reminder.recurrenceRules?.first?.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue), [6])
        XCTAssertEqual(reminder.dueDateComponents?.day, 10, "the due date is not moved")
    }

    func testClearRecurrenceRemovesTheRule() throws {
        let reminder = repeatingReminder()
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", clearRecurrence: true), to: reminder, saved: &saved)
        XCTAssertFalse(reminder.hasRecurrenceRules)
        XCTAssertEqual(reminder.dueDateComponents?.day, 10)
    }

    func testARuleCanBeAddedToAOneOffReminderWithADue() throws {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = thursdayDue
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([5])), to: reminder, saved: &saved)
        XCTAssertTrue(reminder.hasRecurrenceRules)
    }

    /// Every refusal runs before the first write: the reminder keeps its title and rule, nothing is saved.
    func testRefusalsRunBeforeAnyWrite() {
        let cases: [(ReminderUpdateRequest, EKReminder, String)] = [
            (ReminderUpdateRequest(identifier: "r", title: "New", recurrenceRule: weekly([6]), clearRecurrence: true),
             repeatingReminder(), ReminderRecurrenceWrite.bothMessage),
            (ReminderUpdateRequest(identifier: "r", title: "New", clearDueDate: true),
             repeatingReminder(), ReminderRecurrenceWrite.clearDueMessage),
            (ReminderUpdateRequest(identifier: "r", title: "New", clearDueDate: true, recurrenceRule: weekly([6])),
             repeatingReminder(), ReminderRecurrenceWrite.clearDueWithRuleMessage),
            ({ ReminderUpdateRequest(identifier: "r", title: "New", recurrenceRule: weekly([6])) }(),
             { let r = EKReminder(eventStore: SharedTestStore.store); r.title = "weekly"; return r }(), ReminderRecurrenceWrite.noDueMessage),
            (ReminderUpdateRequest(identifier: "r", title: "New", recurrenceRule: weekly([6])),
             { let r = repeatingReminder(); r.isCompleted = true; return r }(), ReminderRecurrenceWrite.completedMessage),
        ]
        for (request, reminder, message) in cases {
            var saved = false
            XCTAssertThrowsError(try apply(request, to: reminder, saved: &saved)) { error in
                XCTAssertEqual("\(error)", "\(ToolError.invalidParameter(message))")
            }
            XCTAssertFalse(saved)
            XCTAssertEqual(reminder.title, "weekly", "nothing was written")
        }
        XCTAssertTrue(ReminderRecurrenceWrite.clearDueWithRuleMessage.contains("Drop clear_due_date"))
        XCTAssertFalse(ReminderRecurrenceWrite.clearDueWithRuleMessage.hasSuffix("Pass due_date. Nothing was written."))
        for message in [ReminderRecurrenceWrite.bothMessage, ReminderRecurrenceWrite.noDueMessage, ReminderRecurrenceWrite.clearDueWithRuleMessage,
                        ReminderRecurrenceWrite.clearDueMessage, ReminderRecurrenceWrite.completedMessage] {
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.contains("Nothing was written") || message.contains("Cannot specify both"), message)
        }
        XCTAssertTrue(ReminderRecurrenceWrite.clearDueMessage.contains("clear_recurrence"))
    }

    /// `clear_due_date` with `clear_recurrence` is the explicit way to make it one-off without a due.
    func testClearDueWithClearRecurrenceIsAccepted() throws {
        let reminder = repeatingReminder()
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", clearDueDate: true, clearRecurrence: true), to: reminder, saved: &saved)
        XCTAssertTrue(saved)
        XCTAssertFalse(reminder.hasRecurrenceRules)
        XCTAssertNil(reminder.dueDateComponents)
    }

    /// A one-off reminder may still drop its due date as before.
    func testClearDueOnAOneOffReminderIsUnchanged() throws {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = thursdayDue
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", clearDueDate: true), to: reminder, saved: &saved)
        XCTAssertTrue(saved)
    }

    func testTheDueIsJudgedAgainstTheRulesDays() {
        let thursday = ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: weekly([5])))
        let friday = ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: weekly([6])))
        let daily = ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
            frequency: .daily, interval: 1, endDate: nil, occurrenceCount: nil, daysOfWeek: nil, daysOfMonth: nil, excludedOccurrenceDates: nil)))
        let monthly15 = ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
            frequency: .monthly, interval: 1, endDate: nil, occurrenceCount: nil, daysOfWeek: nil, daysOfMonth: [15], excludedOccurrenceDates: nil)))
        XCTAssertTrue(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: thursday))
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: friday))
        XCTAssertTrue(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: daily))
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: monthly15))
        XCTAssertTrue(ReminderRecurrenceWrite.dueMatches(DateComponents(year: 2026, month: 12, day: 15), rule: monthly15))
        // A date-only due is judged by its day too.
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(DateComponents(year: 2026, month: 12, day: 10), rule: friday))

        XCTAssertNil(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [thursday], dueGiven: false))
        XCTAssertNil(ReminderRecurrenceWrite.offRuleNote(due: nil, rules: [friday], dueGiven: false))
        XCTAssertNil(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [], dueGiven: false))
        let note = try? XCTUnwrap(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [friday], dueGiven: false))
        XCTAssertTrue(note?.contains("2026-12-10") ?? false, note ?? "")
        XCTAssertTrue(note?.contains("was not moved") ?? false, note ?? "")
        XCTAssertTrue(note?.contains("pass due_date to update_reminder") ?? false, note ?? "")
    }

    /// Read back off the saved reminder: the stored rule, the due, and the note.
    func testTheReadBackComesFromTheSavedReminder() {
        let reminder = repeatingReminder(days: [6])
        let readBack = ReminderRecurrenceWrite.readBack(reminder, request: ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([6])))
        XCTAssertTrue(readBack.hasRecurrence)
        XCTAssertEqual(readBack.rules?.first?.weekdays?.map(\.day), [6])
        XCTAssertEqual(readBack.due?.components.day, 10)
        XCTAssertNotNil(readBack.offRuleNote)
        let oneOff = EKReminder(eventStore: SharedTestStore.store)
        oneOff.dueDateComponents = thursdayDue
        XCTAssertFalse(ReminderRecurrenceWrite.readBack(oneOff, request: ReminderUpdateRequest(identifier: "r", clearRecurrence: true)).hasRecurrence)
        XCTAssertNil(ReminderRecurrenceWrite.readBack(oneOff, request: ReminderUpdateRequest(identifier: "r", clearRecurrence: true)).offRuleNote)
    }

    /// Undo: the recorded snapshot restores the old rule (`ReminderSnapshot.apply`), and the #236
    /// post-state guard compares the rule by value against a separately built reminder.
    func testUndoRestoresTheRuleAndTheGuardComparesItByValue() throws {
        let reminder = repeatingReminder()
        let before = ReminderSnapshot(from: reminder)
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([6])), to: reminder, saved: &saved)
        let post = ReminderSnapshot(from: reminder)

        let readBack = repeatingReminder(days: [6])
        XCTAssertEqual(post.changedFields(in: ReminderSnapshot(from: readBack), restoring: before), [])
        XCTAssertEqual(post.changedFields(in: ReminderSnapshot(from: repeatingReminder(days: [2])), restoring: before), ["recurrence"])

        before.apply(to: reminder, now: Date())
        XCTAssertEqual(reminder.recurrenceRules?.first?.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue), [5])

        // One-off → repeating → undo gives a one-off.
        let oneOff = EKReminder(eventStore: SharedTestStore.store)
        oneOff.dueDateComponents = thursdayDue
        let oneOffBefore = ReminderSnapshot(from: oneOff)
        try apply(ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([5])), to: oneOff, saved: &saved)
        oneOffBefore.apply(to: oneOff, now: Date())
        XCTAssertFalse(oneOff.hasRecurrenceRules)
    }

    /// #333's order holds: the recurrence and alarm checks both run before the first write.
    func testAnAlarmRefusalStillRunsFirstWithARuleChange() {
        let reminder = repeatingReminder()
        var saved = false
        XCTAssertThrowsError(try apply(ReminderUpdateRequest(identifier: "r", title: "New", due: .day(DateComponents(year: 2026, month: 12, day: 11)),
                                                             alarmOffsets: [15], recurrenceRule: weekly([6])),
                                       to: reminder, saved: &saved))
        XCTAssertFalse(saved)
        XCTAssertEqual(reminder.recurrenceRules?.first?.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue), [5])
    }

    // MARK: - PR #420 verify round 1

    /// The read-back is taken after a reload of the saved reminder, not off the object written.
    func testTheReadBackIsTakenAfterTheReload() {
        let reminder = repeatingReminder(days: [6])
        let request = ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([6]))
        var reloaded = false
        let readBack = ReminderRecurrenceWrite.readBackAfterSave(reminder, request: request, reload: {
            reloaded = true
            // What the store holds differs from what was written (a sync, another app).
            reminder.recurrenceRules = [EventKitManager.makeRecurrenceRule(from: self.weekly([2]))]
            return true
        })
        XCTAssertTrue(reloaded)
        XCTAssertTrue(readBack.confirmed)
        XCTAssertEqual(readBack.rules?.first?.weekdays?.map(\.day), [2])
    }

    /// A reminder that cannot be re-read after the save reports nothing as stored.
    func testAFailedReloadIsNotConfirmed() {
        let readBack = ReminderRecurrenceWrite.readBackAfterSave(repeatingReminder(days: [6]),
                                                                 request: ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([6])),
                                                                 reload: { false })
        XCTAssertFalse(readBack.confirmed)
        XCTAssertNil(readBack.rules)
        XCTAssertNil(readBack.offRuleNote)
        XCTAssertTrue(ReminderRecurrenceWrite.unconfirmedNote.contains("could not be re-read"))
    }

    /// The note says whether the due came from this call, and the second sentence is stated as
    /// measured only for the measured shape (a weekly rule naming weekdays).
    func testTheNoteWording() throws {
        let friday = ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: weekly([6])))
        let monthly15 = ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
            frequency: .monthly, interval: 1, endDate: nil, occurrenceCount: nil, daysOfWeek: nil, daysOfMonth: [15], excludedOccurrenceDates: nil)))
        let kept = try XCTUnwrap(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [friday], dueGiven: false))
        XCTAssertTrue(kept.contains("was not moved"), kept)
        XCTAssertTrue(kept.contains("pass due_date to update_reminder"), kept)
        XCTAssertTrue(kept.contains("measured"), kept)
        XCTAssertFalse(kept.contains("not measured"), kept)
        let given = try XCTUnwrap(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [friday], dueGiven: true))
        XCTAssertFalse(given.contains("was not moved"), given)
        XCTAssertTrue(given.contains("given in this call"), given)
        let monthly = try XCTUnwrap(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [monthly15], dueGiven: false))
        XCTAssertTrue(monthly.contains("not measured"), monthly)
        // PR #420 verify round 2: "measured" only for the shape measured: weekly, interval 1, one
        // weekday, no end date or count.
        func weeklyRule(days: [Int], interval: Int = 1, count: Int? = nil, end: Date? = nil) -> ReminderRecurrenceRuleValue {
            ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
                frequency: .weekly, interval: interval, endDate: end, occurrenceCount: count, daysOfWeek: days, daysOfMonth: nil, excludedOccurrenceDates: nil)))
        }
        for rule in [weeklyRule(days: [6], interval: 2), weeklyRule(days: [6, 7]), weeklyRule(days: [6], count: 5),
                     weeklyRule(days: [6], end: Date(timeIntervalSince1970: 1_900_000_000))] {
            let note = try XCTUnwrap(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [rule], dueGiven: false))
            XCTAssertTrue(note.contains("not measured"), note)
        }
    }

    /// Weekdays count for every frequency; days of the month for monthly and yearly only. Measured
    /// on iCloud (#434 verify), for reminders and events: a daily rule with weekdays skips the other
    /// days, a yearly rule with days of the month repeats on them, and a daily or weekly rule
    /// ignores days of the month.
    func testDayListsCountOnlyForTheFrequenciesThatUseThem() {
        func rule(_ frequency: RecurrenceRuleInput.Frequency, days: [Int]? = nil, dom: [Int]? = nil) -> ReminderRecurrenceRuleValue {
            ReminderRecurrenceRuleValue(from: EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
                frequency: frequency, interval: 1, endDate: nil, occurrenceCount: nil, daysOfWeek: days, daysOfMonth: dom, excludedOccurrenceDates: nil)))
        }
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.daily, days: [6])), "daily by weekday")
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.yearly, dom: [15])), "yearly by day of the month")
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.yearly, days: [6])), "yearly by weekday")
        XCTAssertTrue(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.daily, dom: [15])), "daily ignores days of the month")
        XCTAssertTrue(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.weekly, dom: [15])), "weekly ignores days of the month")
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.monthly, days: [6])), "monthly by weekday")
        XCTAssertFalse(ReminderRecurrenceWrite.dueMatches(thursdayDue, rule: rule(.monthly, dom: [15])))
    }

    /// A rule change keeps the reminder's alarms and location trigger.
    func testARuleChangeKeepsAlarmsAndTheLocationTrigger() throws {
        let reminder = repeatingReminder()
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        reminder.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Somewhere")
        reminder.addAlarm(location)
        var saved = false
        try apply(ReminderUpdateRequest(identifier: "r", recurrenceRule: weekly([6])), to: reminder, saved: &saved)
        try apply(ReminderUpdateRequest(identifier: "r", clearRecurrence: true), to: reminder, saved: &saved)
        XCTAssertEqual(reminder.alarms?.count, 3)
        XCTAssertEqual(reminder.alarms?.filter { $0.structuredLocation != nil }.count, 1)
        XCTAssertEqual(reminder.alarms?.compactMap(\.absoluteDate).count, 1)
        XCTAssertEqual(ReminderRelativeAlarms.storedMinutesBefore(reminder), [15])
    }

    /// The post-state guard compares a rule's end by day for a date-only reminder, as for an
    /// all-day event (CalDAV can store the end as a date), and to the second for a timed one.
    func testTheGuardComparesARulesEndByDayForADateOnlyReminder() {
        func reminder(due: DateComponents, end: Date) -> EKReminder {
            let r = EKReminder(eventStore: SharedTestStore.store)
            r.dueDateComponents = due
            r.recurrenceRules = [EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
                frequency: .weekly, interval: 1, endDate: end, occurrenceCount: nil, daysOfWeek: [5], daysOfMonth: nil, excludedOccurrenceDates: nil))]
            return r
        }
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let dateOnly = DateComponents(year: 2026, month: 12, day: 10)
        let post = ReminderSnapshot(from: reminder(due: dateOnly, end: end))
        XCTAssertEqual(post.changedFields(in: ReminderSnapshot(from: reminder(due: dateOnly, end: end.addingTimeInterval(60))), restoring: nil), [])
        // PR #420 verify round 2: the "already restored" comparison too goes by day only when both
        // sides are date-only. A date-only reminder made timed, whose rule end another app then
        // moves within the day, is not taken as restored.
        let target = ReminderSnapshot(from: reminder(due: dateOnly, end: end))
        let timedAfterUpdate = ReminderSnapshot(from: reminder(due: thursdayDue, end: end.addingTimeInterval(-3600)))
        XCTAssertEqual(timedAfterUpdate.changedFields(in: ReminderSnapshot(from: reminder(due: thursdayDue, end: end.addingTimeInterval(60))),
                                                      restoring: target), ["recurrence"])
        let timedPost = ReminderSnapshot(from: reminder(due: thursdayDue, end: end))
        XCTAssertEqual(timedPost.changedFields(in: ReminderSnapshot(from: reminder(due: thursdayDue, end: end.addingTimeInterval(60))), restoring: nil),
                       ["recurrence"])
    }

    /// The store path reads the rule back through `readBackAfterSave` with a reload.
    func testUpdateReminderReadsTheRuleBackAfterAReload() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        XCTAssertEqual(code.components(separatedBy: "ReminderRecurrenceWrite.readBackAfterSave(reminder, request: request, reload: { reminder.refresh() })").count - 1, 1)
        XCTAssertFalse(code.filter { !$0.isWhitespace }.contains("ReminderRecurrenceWrite.readBack(reminder"))
    }
}
