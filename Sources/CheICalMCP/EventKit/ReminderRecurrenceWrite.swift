import EventKit
import Foundation

/// #354: `update_reminder`'s `recurrence` (replaces the reminder's rule) and `clear_recurrence`
/// (removes it), with the checks that run before the first write and the read-back.
///
/// Measured on iCloud (2026-11-05, #354): a weekday change keeps the due date and the identifier;
/// the pending occurrence stays on its day, and after it is completed the series continues on the
/// rule's days. Clearing keeps the due. `clear_due_date` on a repeating reminder fails at the save
/// (EKErrorDomain 18: a repeating reminder must have a due date). So:
/// - the due date is never moved by a rule change (default, can be revisited); when it is not on
///   the new rule's days the response says so (`offRuleNote`);
/// - a rule needs a due date after the call, and `clear_due_date` on a reminder that keeps
///   repeating is refused by name before any write; with `clear_recurrence` it is accepted;
/// - a rule is not set on a completed reminder (its rollover with a new rule was not measured).
enum ReminderRecurrenceWrite {
    /// What the saved reminder reads back as: the rule, the due, and the note.
    struct ReadBack: Sendable {
        let hasRecurrence: Bool
        let rules: [ReminderRecurrenceRuleValue]?
        let due: ReminderDueValue?
        let offRuleNote: String?
    }

    static let bothMessage = "Cannot specify both recurrence and clear_recurrence"
    static let noDueMessage = "recurrence needs a due date: the reminder will have none after this call, and a repeating reminder must have one. Pass due_date. Nothing was written."
    static let clearDueMessage = "clear_due_date is refused: the reminder repeats, and a repeating reminder must have a due date. To make it a one-off reminder without a due date, pass clear_recurrence: true with clear_due_date. Nothing was written."
    static let completedMessage = "recurrence cannot be set on a completed reminder: how a completed reminder rolls over with a new rule has not been measured. Mark it incomplete first (complete_reminder with completed: false). Nothing was written."

    /// The refusals, before any write. `repeats` and `isCompleted` are the reminder's state before
    /// the call; `existingDue` its stored due.
    static func check(_ request: ReminderUpdateRequest, existingDue: DateComponents?, repeats: Bool, isCompleted: Bool) throws {
        if request.recurrenceRule != nil && request.clearRecurrence {
            throw ToolError.invalidParameter(bothMessage)
        }
        let dueAfter = ReminderRelativeAlarms.dueState(requested: request.due, clearDue: request.clearDueDate, existing: existingDue)
        if request.recurrenceRule != nil {
            if dueAfter == .none { throw ToolError.invalidParameter(noDueMessage) }
            if isCompleted { throw ToolError.invalidParameter(completedMessage) }
        } else if request.clearDueDate, repeats, !request.clearRecurrence {
            throw ToolError.invalidParameter(clearDueMessage)
        }
    }

    /// Writes the rule change, if any. Run after the due date is written, in the same save
    /// (EventKit refuses a repeating reminder without a due date at the save).
    static func write(_ request: ReminderUpdateRequest, to reminder: EKReminder) {
        if request.clearRecurrence {
            reminder.recurrenceRules = nil
        } else if let rule = request.recurrenceRule {
            reminder.recurrenceRules = [EventKitManager.makeRecurrenceRule(from: rule)]
        }
    }

    /// Whether `due`'s day is one the rule names: a weekday in `days_of_week`, a day in
    /// `days_of_month`. A rule that names neither repeats from the due itself, so it matches. The
    /// weekday is the label's (year, month, day), whatever the zone.
    static func dueMatches(_ due: DateComponents, rule: ReminderRecurrenceRuleValue) -> Bool {
        if let weekdays = rule.weekdays, !weekdays.isEmpty {
            guard let weekday = weekday(of: due) else { return true }
            if !weekdays.contains(where: { $0.day == weekday }) { return false }
        }
        if let days = rule.daysOfMonth, !days.isEmpty, let day = due.day {
            if !days.contains(day) { return false }
        }
        return true
    }

    /// The note when the due is not on the rule's days: it was not moved, the pending occurrence
    /// stays on it, and how to move it. Nil without a due or a rule, or when it matches.
    static func offRuleNote(due: DateComponents?, rules: [ReminderRecurrenceRuleValue]) -> String? {
        guard let due, let rule = rules.first, !dueMatches(due, rule: rule),
              let year = due.year, let month = due.month, let day = due.day else { return nil }
        let label = String(format: "%04d-%02d-%02d", year, month, day)
        return "The due date (\(label)) is not on the new rule's days and was not moved: this pending occurrence stays on it, and after it is completed the reminder repeats on the rule's days. To move it, pass due_date in the same call."
    }

    static func readBack(_ reminder: EKReminder) -> ReadBack {
        let rules = reminder.recurrenceRules?.map(ReminderRecurrenceRuleValue.init(from:))
        return ReadBack(hasRecurrence: reminder.hasRecurrenceRules, rules: rules,
                        due: ReminderDueValue(components: reminder.dueDateComponents),
                        offRuleNote: reminder.hasRecurrenceRules ? offRuleNote(due: reminder.dueDateComponents, rules: rules ?? []) : nil)
    }

    private static func weekday(of components: DateComponents) -> Int? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return calendar.component(.weekday, from: date)
    }
}
