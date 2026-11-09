import CoreLocation
import EventKit

/// #459: the fields a write of an existing reminder copies from the object the caller changed (on
/// the long-lived store) onto the same reminder looked up on the write store.
///
/// The list is closed: these are the writable properties of `EKReminder` and `EKCalendarItem` a
/// reminder carries. A property added to EventKit, or to what this server writes, has to be added
/// here, or the write silently leaves it out. Only a value that differs is written, so an unchanged
/// alarm or rule is not rebuilt. Alarms and rules compare as sets of values: EventKit keeps alarms
/// in its own order.
///
/// Alarms and recurrence rules are built anew with the same values: putting the long-lived store's
/// `EKAlarm` on the write store's reminder ended the process, and so did a rule passed through
/// `copy()` (measured 2026-11-09, one process).
enum ReminderFieldCopy {
    static let fields = ["title", "location", "notes", "url", "timeZone", "startDateComponents",
                         "dueDateComponents", "priority", "isCompleted", "completionDate",
                         "alarms", "recurrenceRules", "calendar"]

    /// Throws `EventKitError.writeStoreLookupFailed` before writing anything when the write store
    /// cannot see the reminder's list.
    static func apply(from source: EKReminder, to target: EKReminder, calendar lookup: (String) -> EKCalendar?) throws {
        var list: EKCalendar?
        if let sourceList = source.calendar {
            guard let found = lookup(sourceList.calendarIdentifier) else {
                throw EventKitError.writeStoreLookupFailed(kind: "reminder list")
            }
            list = found
        }
        if target.title != source.title { target.title = source.title }
        if target.location != source.location { target.location = source.location }
        if target.notes != source.notes { target.notes = source.notes }
        if target.url != source.url { target.url = source.url }
        if target.timeZone != source.timeZone { target.timeZone = source.timeZone }
        if target.startDateComponents != source.startDateComponents { target.startDateComponents = source.startDateComponents }
        if target.dueDateComponents != source.dueDateComponents { target.dueDateComponents = source.dueDateComponents }
        if target.priority != source.priority { target.priority = source.priority }
        if target.isCompleted != source.isCompleted { target.isCompleted = source.isCompleted }
        if target.completionDate != source.completionDate { target.completionDate = source.completionDate }
        let sourceAlarms = source.alarms ?? []
        if (target.alarms ?? []).map(alarmSignature).sorted() != sourceAlarms.map(alarmSignature).sorted() {
            target.alarms = sourceAlarms.isEmpty ? nil : sourceAlarms.map(copyAlarm)
        }
        let sourceRules = source.recurrenceRules ?? []
        if (target.recurrenceRules ?? []).map(ruleSignature).sorted() != sourceRules.map(ruleSignature).sorted() {
            target.recurrenceRules = sourceRules.isEmpty ? nil : sourceRules.map(copyRule)
        }
        if let list, target.calendar?.calendarIdentifier != list.calendarIdentifier { target.calendar = list }
    }

    static func alarmSignature(_ alarm: EKAlarm) -> String {
        var parts = ["rel:\(alarm.relativeOffset)", "abs:\(alarm.absoluteDate?.timeIntervalSince1970.description ?? "-")",
                     "prox:\(alarm.proximity.rawValue)"]
        if let place = alarm.structuredLocation {
            let geo = place.geoLocation.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" } ?? "-"
            parts.append("loc:\(place.title ?? "")|\(geo)|\(place.radius)")
        }
        if let email = alarm.emailAddress { parts.append("email:\(email)") }
        if let sound = alarm.soundName { parts.append("sound:\(sound)") }
        return parts.joined(separator: ";")
    }

    static func copyAlarm(_ alarm: EKAlarm) -> EKAlarm {
        let copy = alarm.absoluteDate.map { EKAlarm(absoluteDate: $0) } ?? EKAlarm(relativeOffset: alarm.relativeOffset)
        if let place = alarm.structuredLocation {
            let newPlace = EKStructuredLocation(title: place.title ?? "")
            newPlace.geoLocation = place.geoLocation
            newPlace.radius = place.radius
            copy.structuredLocation = newPlace
        }
        copy.proximity = alarm.proximity
        if let email = alarm.emailAddress { copy.emailAddress = email }
        if let sound = alarm.soundName { copy.soundName = sound }
        return copy
    }

    static func ruleSignature(_ rule: EKRecurrenceRule) -> String {
        let days = rule.daysOfTheWeek?.map { "\($0.dayOfTheWeek.rawValue)/\($0.weekNumber)" }.joined(separator: ",") ?? "-"
        func list(_ xs: [NSNumber]?) -> String { xs?.map(\.stringValue).joined(separator: ",") ?? "-" }
        let end = rule.recurrenceEnd.map { e in e.endDate.map { "date:\($0.timeIntervalSince1970)" } ?? "count:\(e.occurrenceCount)" } ?? "-"
        return ["f:\(rule.frequency.rawValue)", "i:\(rule.interval)", "dw:\(days)", "dm:\(list(rule.daysOfTheMonth))",
                "my:\(list(rule.monthsOfTheYear))", "wy:\(list(rule.weeksOfTheYear))", "dy:\(list(rule.daysOfTheYear))",
                "sp:\(list(rule.setPositions))", "end:\(end)"].joined(separator: ";")
    }

    static func copyRule(_ rule: EKRecurrenceRule) -> EKRecurrenceRule {
        let end = rule.recurrenceEnd.map { e in e.endDate.map { EKRecurrenceEnd(end: $0) } ?? EKRecurrenceEnd(occurrenceCount: e.occurrenceCount) }
        let days = rule.daysOfTheWeek?.map { $0.weekNumber == 0 ? EKRecurrenceDayOfWeek($0.dayOfTheWeek)
                                                                 : EKRecurrenceDayOfWeek($0.dayOfTheWeek, weekNumber: $0.weekNumber) }
        return EKRecurrenceRule(recurrenceWith: rule.frequency, interval: rule.interval, daysOfTheWeek: days,
                                daysOfTheMonth: rule.daysOfTheMonth, monthsOfTheYear: rule.monthsOfTheYear,
                                weeksOfTheYear: rule.weeksOfTheYear, daysOfTheYear: rule.daysOfTheYear,
                                setPositions: rule.setPositions, end: end)
    }
}

/// #459: the fields a rename or recolor of a reminder list copies onto the write store's list.
enum ListFieldCopy {
    static let fields = ["title", "cgColor"]

    static func apply(from source: EKCalendar, to target: EKCalendar) {
        if target.title != source.title { target.title = source.title }
        if target.cgColor != source.cgColor { target.cgColor = source.cgColor }
    }
}
