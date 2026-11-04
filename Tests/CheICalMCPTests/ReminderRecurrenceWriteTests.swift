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
             repeatingReminder(), ReminderRecurrenceWrite.noDueMessage),
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
        for message in [ReminderRecurrenceWrite.bothMessage, ReminderRecurrenceWrite.noDueMessage,
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

        XCTAssertNil(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [thursday]))
        XCTAssertNil(ReminderRecurrenceWrite.offRuleNote(due: nil, rules: [friday]))
        XCTAssertNil(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: []))
        let note = try? XCTUnwrap(ReminderRecurrenceWrite.offRuleNote(due: thursdayDue, rules: [friday]))
        XCTAssertTrue(note?.contains("2026-12-10") ?? false, note ?? "")
        XCTAssertTrue(note?.contains("was not moved") ?? false, note ?? "")
        XCTAssertTrue(note?.contains("due_date") ?? false, note ?? "")
    }

    /// Read back off the saved reminder: the stored rule, the due, and the note.
    func testTheReadBackComesFromTheSavedReminder() {
        let reminder = repeatingReminder(days: [6])
        let readBack = ReminderRecurrenceWrite.readBack(reminder)
        XCTAssertTrue(readBack.hasRecurrence)
        XCTAssertEqual(readBack.rules?.first?.weekdays?.map(\.day), [6])
        XCTAssertEqual(readBack.due?.components.day, 10)
        XCTAssertNotNil(readBack.offRuleNote)
        let oneOff = EKReminder(eventStore: SharedTestStore.store)
        oneOff.dueDateComponents = thursdayDue
        XCTAssertFalse(ReminderRecurrenceWrite.readBack(oneOff).hasRecurrence)
        XCTAssertNil(ReminderRecurrenceWrite.readBack(oneOff).offRuleNote)
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
}
