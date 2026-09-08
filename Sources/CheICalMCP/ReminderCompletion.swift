import EventKit
import Foundation

/// Values captured inside EventKitManager's actor, before an EKReminder can roll over.
struct ReminderCompletionSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let calendarID: String
    let sourceID: String
    let isCompleted: Bool
    let hasRecurrence: Bool
    let due: ReminderDueValue?
    let rules: [ReminderRecurrenceRuleValue]?
    /// The completion instant as EventKit recorded it (#196) — restored by undo
    /// instead of re-stamping "now". Not occurrence identity.
    let completionDate: Date?

    init(id: String, title: String, calendarID: String, sourceID: String,
         isCompleted: Bool, hasRecurrence: Bool, due: ReminderDueValue?,
         rules: [ReminderRecurrenceRuleValue]?, completionDate: Date?) {
        self.id = id
        self.title = title
        self.calendarID = calendarID
        self.sourceID = sourceID
        self.isCompleted = isCompleted
        self.hasRecurrence = hasRecurrence
        self.due = due
        self.rules = rules
        self.completionDate = completionDate
    }

    init(from reminder: EKReminder) {
        self.init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                  calendarID: reminder.calendar?.calendarIdentifier ?? "",
                  sourceID: reminder.calendar?.source?.sourceIdentifier ?? "",
                  isCompleted: reminder.isCompleted, hasRecurrence: reminder.hasRecurrenceRules,
                  due: ReminderDueValue(components: reminder.dueDateComponents),
                  rules: reminder.recurrenceRules?.map { ReminderRecurrenceRuleValue(from: $0) },
                  completionDate: reminder.completionDate)
    }

    /// Whether this snapshot carries enough immutable identity to be matched
    /// later. A recurring item needs a due and rules to compare by value; it
    /// does NOT need an orderable instant or a mapped frequency — those are
    /// `ReminderNextOccurrence.evaluate`'s preconditions, not identity's, and
    /// requiring them here would route DST-fold or unknown-frequency items to
    /// the unguarded legacy record. Reflexive by construction:
    /// `x.matchesOccurrence(x)` holds whenever `x.isIdentifiable`.
    var isIdentifiable: Bool {
        guard !id.isEmpty, !calendarID.isEmpty, !sourceID.isEmpty else { return false }
        guard hasRecurrence else { return true }
        guard due != nil, let rules, !rules.isEmpty else { return false }
        return true
    }

    /// Completion state and title are not occurrence identity: the same
    /// identifier resolving to a later due date is a different occurrence.
    func matchesOccurrence(_ other: Self) -> Bool {
        guard isIdentifiable, other.isIdentifiable else { return false }
        return id == other.id && calendarID == other.calendarID && sourceID == other.sourceID
            && hasRecurrence == other.hasRecurrence && due == other.due && rules == other.rules
    }
}

/// An observation, never a recurrence calculation or an inferred series end.
struct ReminderNextOccurrence: Equatable, Sendable {
    let status: String
    let reason: String?
    let reminder: ReminderCompletionSnapshot?

    private init(status: String, reason: String? = nil, reminder: ReminderCompletionSnapshot? = nil) {
        self.status = status
        self.reason = reason
        self.reminder = reminder
    }

    static let notApplicable = Self(status: "not_applicable")

    static func unknown(reason: String) -> Self {
        Self(status: "unknown", reason: reason)
    }

    static func evaluate(before: ReminderCompletionSnapshot,
                         observed: ReminderCompletionSnapshot?, requestedCompleted: Bool) -> Self {
        guard requestedCompleted, before.hasRecurrence, !before.isCompleted else {
            return .notApplicable
        }
        guard let observed else { return .unknown(reason: "observation_unavailable") }
        guard !before.id.isEmpty, !before.calendarID.isEmpty, !before.sourceID.isEmpty,
              before.id == observed.id, before.calendarID == observed.calendarID,
              before.sourceID == observed.sourceID else {
            return .unknown(reason: "identity_changed")
        }
        guard observed.hasRecurrence, let rules = before.rules, !rules.isEmpty,
              rules.allSatisfy({ $0.frequency != "unknown" }),
              rules == observed.rules else { return .unknown(reason: "recurrence_unverified") }
        guard !observed.isCompleted else { return .unknown(reason: "successor_not_observed") }
        guard let originalDue = before.due, let observedDue = observed.due,
              originalDue.hasSamePrecisionAndTimeZone(as: observedDue),
              let originalDate = originalDue.chronologicalDate,
              let observedDate = observedDue.chronologicalDate else {
            return .unknown(reason: "due_not_comparable")
        }
        guard observedDate > originalDate else { return .unknown(reason: "due_not_advanced") }
        return Self(status: "confirmed", reminder: observed)
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = ["status": status, "reminder": NSNull()]
        if let reason { value["reason"] = reason }
        if let reminder {
            value["reminder"] = [
                "id": reminder.id, "title": reminder.title,
                "is_completed": reminder.isCompleted,
                "due": reminder.due.map { $0.dictionary as Any } ?? NSNull()
            ] as [String: Any]
        }
        return value
    }
}

struct ReminderCompletionResult: Sendable {
    let before: ReminderCompletionSnapshot
    let afterSave: ReminderCompletionSnapshot
    let requestedCompleted: Bool
    let nextOccurrence: ReminderNextOccurrence

    /// The reminder's own wall clock (plus its zone when it has one) — never a
    /// UTC instant, which can name a different calendar day than the user set.
    private static func dueDescription(_ due: ReminderDueValue?) -> String? {
        guard let due else { return nil }
        let wire = due.dictionary
        guard let date = wire["date"] as? String else { return nil }
        var parts = [date]
        if let time = wire["time"] as? String { parts.append(time) }
        if let zone = wire["timezone"] as? String { parts.append(zone) }
        return parts.joined(separator: " ")
    }

    var dictionary: [String: Any] {
        let message: String
        if !requestedCompleted {
            message = "The request to reopen this reminder was saved successfully."
        } else if before.isCompleted {
            message = "This reminder was already completed; the requested state was saved successfully."
        } else if before.hasRecurrence {
            if nextOccurrence.status == "confirmed",
               let dueText = Self.dueDescription(nextOccurrence.reminder?.due) {
                // #194 asks for "completed; next occurrence <date>".
                message = "This occurrence was completed successfully. Next occurrence: \(dueText) (observed, still incomplete)."
            } else if nextOccurrence.status == "confirmed" {
                message = "This occurrence was completed successfully. The observed next occurrence remains incomplete."
            } else {
                message = "This occurrence was completed successfully. The next occurrence could not be confirmed."
            }
        } else {
            message = "This reminder was completed successfully."
        }
        return [
            // Retain legacy semantics. operation is authoritative for the write outcome.
            "action": "completed",
            "id": before.id,
            "title": afterSave.title,
            "is_completed": afterSave.isCompleted,
            "has_recurrence": before.hasRecurrence,
            // The saved object as read right after save — present even when no
            // successor can be confirmed, so `unknown` still says where the item sits.
            "observed": [
                "id": afterSave.id, "title": afterSave.title,
                "is_completed": afterSave.isCompleted, "has_recurrence": afterSave.hasRecurrence,
                "due": afterSave.due.map { $0.dictionary as Any } ?? NSNull()
            ] as [String: Any],
            "operation": [
                "type": requestedCompleted ? "complete" : "reopen",
                "status": "succeeded",
                "requested_completed": requestedCompleted,
                "target": [
                    "id": before.id,
                    "due": before.due.map { $0.dictionary as Any } ?? NSNull(),
                    "was_completed": before.isCompleted
                ] as [String: Any]
            ] as [String: Any],
            "next_occurrence": nextOccurrence.dictionary,
            "message": message
        ]
    }
}

/// The write an undo / redo / snapshot-restore performs on a reminder's
/// completion state (#196). Pure so the decision is unit-testable; the manager
/// applies it. Setting `isCompleted` alone makes EventKit stamp "now", so a
/// restore to completed must write the recorded instant afterwards.
struct ReminderCompletionWrite: Equatable, Sendable {
    let isCompleted: Bool
    let completionDate: Date?

    /// Completed → the recorded instant when there is one, else `now` (redo has no
    /// recorded instant: a completion re-applied is a fresh completion). Incomplete →
    /// no instant.
    static func plan(isCompleted: Bool, recorded: Date?, now: Date) -> ReminderCompletionWrite {
        isCompleted ? ReminderCompletionWrite(isCompleted: true, completionDate: recorded ?? now)
                    : ReminderCompletionWrite(isCompleted: false, completionDate: nil)
    }

    /// EventKit stamps `completionDate = now` whenever `isCompleted` flips to true,
    /// so the instant is written after the flag; the incomplete branch writes `nil`
    /// explicitly rather than relying on the same coupling in reverse.
    func apply(to reminder: EKReminder) {
        reminder.isCompleted = isCompleted
        reminder.completionDate = completionDate
    }
}

/// A feature-specific seam; do not widen the cleanup protocol for completion.
protocol ReminderCompletionSource: Sendable {
    func completeReminder(identifier: String, completed: Bool) async throws -> ReminderCompletionResult
}
