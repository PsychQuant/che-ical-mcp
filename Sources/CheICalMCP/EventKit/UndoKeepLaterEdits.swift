import EventKit
import Foundation

/// #265 — the opt-in merge of an update-undo (`undo` with `keep_later_edits: true`). By default an
/// update-undo writes every recorded field back, so the post-state guard refuses when any of them
/// changed after the update (#236). With the flag, the undo of an `update_event` on a one-off event,
/// or of an `update_reminder`, restores only the groups of fields the update changed and keeps the
/// later edits in the others; it refuses as before when a later edit is in a group the update changed.
///
/// A **group** is fields that move together, so that a restore never writes half of one: an
/// event's start, end, all-day flag and time zone; its location and place (`apply` writes the
/// location, and EventKit couples the place to it); a reminder's due date, start date, alarms and
/// repetition (written together by `ReminderDateSync.restore`, alarms ride on the due date, and
/// EventKit refuses a repeating reminder without a due date, EKErrorDomain 18). Every other field is a
/// group of its own. The comparison and the masked restore use the same table. A field outside it
/// (`item_type`, an event's `recurrence`) is never merged: the undo refuses as before.
enum UndoKeepLaterEdits {
    static let eventGroups: [[String]] = [
        ["start_time", "end_time", "all_day", "timezone"],
        ["location", "structured_location"],
        ["title"], ["calendar"], ["notes"], ["url"], ["alarms"], ["availability"],
    ]

    static let reminderGroups: [[String]] = [
        ["due_date", "start_date", "alarms", "recurrence"],
        ["title"], ["list"], ["notes"], ["priority"], ["url"], ["completed", "completion_date"],
    ]

    /// `restored`: every field of the groups the update changed, in table order (what the masked
    /// restore writes). `kept`: the fields changed later in other groups. `overlapping`: the fields
    /// changed later in a group the update changed; any of them refuses the merge.
    struct Plan: Equatable, Sendable {
        let restored: [String]
        let kept: [String]
        let overlapping: [String]
    }

    /// Nil when a field of either list is not in `groups`: such a change is never merged.
    static func plan(changedByUpdate: [String], changedElsewhere: [String], groups: [[String]]) -> Plan? {
        func group(of field: String) -> Int? { groups.firstIndex { $0.contains(field) } }
        var updated = Set<Int>()
        for field in changedByUpdate {
            guard let index = group(of: field) else { return nil }
            updated.insert(index)
        }
        var kept: [String] = []
        var overlapping: [String] = []
        for field in changedElsewhere {
            guard let index = group(of: field) else { return nil }
            if updated.contains(index) { overlapping.append(field) } else { kept.append(field) }
        }
        let restored = groups.indices.filter(updated.contains).flatMap { groups[$0] }
        return Plan(restored: restored, kept: kept, overlapping: overlapping)
    }

    /// The text the refusal of an update-undo adds (A): what the update changed and what changed
    /// after it, separately; and (C) when no group overlaps, the way on with `keep_later_edits`.
    /// Field names come from the closed table above, so the text stays author-controlled.
    static func refusalNote(changedByUpdate: [String], changedElsewhere: [String], groups: [[String]]) -> String? {
        let updated = changedByUpdate.isEmpty ? "none of the fields undo restores" : changedByUpdate.joined(separator: ", ")
        var note = "The update changed: \(updated). Changed after it: \(changedElsewhere.joined(separator: ", "))."
        guard let plan = plan(changedByUpdate: changedByUpdate, changedElsewhere: changedElsewhere, groups: groups) else {
            return note + " keep_later_edits cannot keep this change."
        }
        let together = groups == reminderGroups
            ? "a reminder's due date, start date, alarms and repetition count as one"
            : "an event's start, end, all-day flag and time zone count as one, and so do its location and place"
        if plan.overlapping.isEmpty {
            note += " The later edits are not in what the update changed (\(together)), so undo can restore only what the update changed and keep them: ask the user first, then call undo with keep_later_edits set to true."
        } else {
            note += " The later edit to \(plan.overlapping.joined(separator: ", ")) is in what the update changed (\(together)), so keep_later_edits cannot keep it."
        }
        return note
    }

    /// What `undo` with `keep_later_edits` answers after the masked restore. Titles through
    /// `undoVisibleTitle`, field names from the table.
    static func undoneMessage(kind: UndoPostState.Kind, title: String, plan: Plan) -> String {
        let restored = plan.restored.isEmpty ? "nothing (the update changed none of the fields undo restores)" : plan.restored.joined(separator: ", ")
        let kept = plan.kept.isEmpty ? "" : "; kept the later edits to \(plan.kept.joined(separator: ", "))"
        return "Undone: restored \(kind.rawValue) '\(undoVisibleTitle(title))' in \(restored)\(kept)"
    }
}

extension EventSnapshot {
    /// #265: the masked restore of an update-undo with `keep_later_edits`. Writes only `fields`
    /// (whole groups of `UndoKeepLaterEdits.eventGroups`), in `apply`'s order. A separate function, so
    /// `apply`, which delete-undo and the batch restore use to recreate whole events, is unchanged.
    func applyRestoring(_ fields: Set<String>, to event: EKEvent, calendar: EKCalendar) {
        if fields.contains("title") { event.title = title }
        if fields.contains("start_time") { event.startDate = startDate }
        if fields.contains("end_time") { event.endDate = endDate }
        if fields.contains("notes") { event.notes = notes }
        if fields.contains("location") { event.location = location }
        if fields.contains("url") { event.url = url }
        if fields.contains("all_day") { event.isAllDay = isAllDay }
        if fields.contains("calendar") { event.calendar = calendar }
        if fields.contains("availability"), let target = event.calendar,
           let value = Self.availabilityToWrite(recorded: availability, supported: target.supportedEventAvailabilities,
                                                current: event.availability) {
            event.availability = value
        }
        if fields.contains("alarms") { AlarmSnapshot.restore(alarms, to: event) }
        if fields.contains("structured_location"), let locTitle = structuredLocationTitle {
            let structured = EKStructuredLocation(title: locTitle)
            if let lat = structuredLocationLat, let lon = structuredLocationLon {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            if let radius = structuredLocationRadius, radius > 0 {
                structured.radius = radius
            }
            event.structuredLocation = structured
        }
        if fields.contains("timezone") { event.timeZone = timeZone }
    }
}

extension ReminderSnapshot {
    /// #265: the reminder counterpart of `EventSnapshot.applyRestoring`, in `apply(to:now:)`'s
    /// order; the date group goes through `ReminderDateSync.restore` with the alarms and rules in
    /// the same save, as there. `list` is the resolved recorded list, written when `list` is restored.
    func applyRestoring(_ fields: Set<String>, to reminder: EKReminder, list: EKCalendar?, now: Date) {
        if fields.contains("list"), let list { reminder.calendar = list }
        if fields.contains("title") { reminder.title = title }
        if fields.contains("notes") { reminder.notes = notes }
        if fields.contains("completed") || fields.contains("completion_date") {
            ReminderCompletionWrite.plan(isCompleted: isCompleted, recorded: completionDate, now: now).apply(to: reminder)
        }
        if fields.contains("priority") { reminder.priority = priority }
        if fields.contains("due_date") {
            ReminderDateSync.restore(reminder, start: startDateComponents, due: dueDateComponents)
        }
        if fields.contains("url") { reminder.url = url }
        if fields.contains("due_date") {
            AlarmSnapshot.restore(alarms, to: reminder)
            if (reminder.recurrenceRules ?? []).map(RecurrenceRuleSnapshot.init(from:)) != recurrenceRules {
                reminder.recurrenceRules = recurrenceRules.isEmpty ? nil : recurrenceRules.map { $0.rebuild() }
            }
        }
    }
}
