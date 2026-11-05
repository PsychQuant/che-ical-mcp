import EventKit
import Foundation

/// #423: the next occurrence's relative alarms after `complete_reminder` rolls a repeating
/// reminder over, read after a reload, and the ones that were not there before.
///
/// Measured on iCloud (2026-11-05, `--cli`): completing a repeating reminder that has a location
/// trigger leaves one plain relative alarm at 0 minutes (no location, no proximity) on the next
/// occurrence and on the completed copy; without a location trigger, without recurrence, or
/// without a completion nothing is added, and a later completion does not add another (with that
/// alarm still there, or after it was removed). This path sets only `isCompleted` and
/// `completionDate`, so EventKit or the store adds the alarm when that save rolls the reminder
/// over; which of the two was not told apart. This only reports it; nothing is written. Whether
/// the alarm fires and whether Reminders.app shows it were not checked (release gate). The
/// completed copy gets a new identifier and is not read here.
///
/// A read-back cannot tell who wrote an alarm: the actor rules out this server's other calls, not
/// another process (Reminders.app, a sync, a second server process). So `note` says the alarm
/// appeared, and only the measured shape is attributed to the rollover (PR #425 verify).
struct ReminderRolloverAlarms: Equatable, Sendable {
    /// False when the reminder could not be re-read, or was no longer the occurrence the rollover
    /// was confirmed on: nothing is reported as stored.
    let readBack: Bool
    /// Relative alarms on the next occurrence, minutes before its due date, earliest first.
    let minutesBefore: [Double]
    /// The relative alarms in `minutesBefore` that were not on the reminder before the call.
    let added: [Double]

    static let unreadNote = "The next occurrence could not be re-read after the save, or it had changed by then, so its alarms are not reported; read it with list_reminders."

    static func note(added: [Double]) -> String {
        let values = added.map { "minutes_before: \(Self.format($0))" }.joined(separator: ", ")
        let what = added.count == 1 ? "A relative alarm" : "\(added.count) relative alarms"
        let was = added.count == 1 ? "was" : "were"
        return "\(what) (\(values)) appeared on the next occurrence when it was read back, and \(was) not there before this completion. This call sets only the completion fields, yet on iCloud the save that rolls over a repeating reminder with a location trigger leaves a 0-minute relative alarm; one written by another app or a sync would look the same here. Whether it fires and whether Reminders.app shows it are not checked. update_reminder with alarms_minutes_offsets replaces the relative alarms."
    }

    /// What `after` holds beyond `before`, as multisets.
    static func added(before: [Double], after: [Double]) -> [Double] {
        var remaining = before
        var extra: [Double] = []
        for value in after {
            if let index = remaining.firstIndex(of: value) { remaining.remove(at: index) } else { extra.append(value) }
        }
        return extra
    }

    /// After `reload` (`EKObject.refresh()`, then a snapshot of the object; nil when it fails), the
    /// relative alarms on `item` compared with `before`. Nil unless `next` is a confirmed rollover,
    /// and `reload` does not run then: the identifier only names the next occurrence after one.
    /// What `reload` found must still be that occurrence, in the same completion state; otherwise
    /// its alarms belong to something `next_occurrence` does not describe and nothing is claimed.
    static func observe(before: [Double], next: ReminderNextOccurrence, item: EKReminder,
                        reload: () -> ReminderCompletionSnapshot?) -> Self? {
        guard next.status == .confirmed, let confirmed = next.reminder else { return nil }
        guard let reloaded = reload(), confirmed.matchesOccurrence(reloaded),
              confirmed.isCompleted == reloaded.isCompleted else {
            return Self(readBack: false, minutesBefore: [], added: [])
        }
        let after = ReminderRelativeAlarms.storedMinutesBefore(item)
        return Self(readBack: true, minutesBefore: after, added: added(before: before, after: after))
    }

    /// Merged into `next_occurrence`.
    var nextOccurrenceFields: [String: Any] {
        readBack ? ["alarms_minutes_offsets": minutesBefore] : ["alarms_read_back": false]
    }

    /// Merged into the top level of the response.
    var topLevelFields: [String: Any] {
        if !readBack { return ["alarms_read_back_note": Self.unreadNote] }
        return added.isEmpty ? [:] : ["alarms_note": Self.note(added: added)]
    }

    /// The value comes from a re-read, so any other writer can have set it: not bounded by the
    /// range `alarms_minutes_offsets` accepts, and `Int(_:)` traps out of `Int`'s range.
    private static func format(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(value)
    }
}
