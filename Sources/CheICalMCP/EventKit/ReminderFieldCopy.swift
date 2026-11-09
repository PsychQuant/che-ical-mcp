import CoreLocation
import EventKit

/// #459: what a write of an existing reminder copies from the object the caller changed (on the
/// long-lived store) onto the same reminder looked up on the write store.
///
/// **Only the fields this call changed are written** (PR #507 round 1). The change is the
/// difference between the caller's object as it is now and as it was before the call
/// (`Values` taken after `rollback()`), not the difference from the write store's copy: that copy
/// reads the stored state, and a field the call did not touch may be newer there (changed on
/// another device). Writing it from the caller's cached value would undo that change.
///
/// The field list is closed: these are the writable properties of `EKReminder` and
/// `EKCalendarItem` a reminder carries. A property added to EventKit, or to what this server
/// writes, has to be added here, or the write silently leaves it out.
///
/// - Dates go through `ReminderDateSync.restore` (start and due in its order, #235/#237), with the
///   stored start or due for whichever the call did not change, and the zone after them. The #237
///   fallback's second save (`writeDueAroundStart`: clear the start, write the due, put the start
///   back) therefore reaches the write store as its final values in `restore`'s order, not in the
///   fallback's own order (PR #507 round 2 INFO 10; not measured on a source that drops the zone).
/// - Alarms are three fields, one per kind (relative, absolute, location; `AlarmSnapshot.Kind`), and
///   each goes through `AlarmSnapshot.restore(_:to:kind:)` against the target's own alarms of that
///   kind (PR #507 round 3): `alarms_minutes_offsets` replaces the relative alarms only, so an
///   absolute or location alarm another store added since the cache read stays, and the other way
///   round. An alarm equal to a wanted one stays the same object, so what no snapshot rebuilds (a
///   procedure alarm's URL) survives, and no alarm object of the long-lived store is put on the
///   target (doing so ended the process, measured 2026-11-09).
/// - Recurrence rules are built anew with the same values (a rule passed through `copy()` also
///   ended the process).
enum ReminderFieldCopy {
    enum Field: String, CaseIterable, Hashable {
        case title, location, notes, url, timeZone, startDateComponents, dueDateComponents, priority,
             isCompleted, completionDate, relativeAlarms, absoluteAlarms, locationAlarms, recurrenceRules, calendar

        /// The alarm field of each kind.
        static func alarms(_ kind: AlarmSnapshot.Kind) -> Field {
            switch kind {
            case .relative: return .relativeAlarms
            case .absolute: return .absoluteAlarms
            case .location: return .locationAlarms
            }
        }
    }

    static let fields = Field.allCases.map(\.rawValue)

    /// What a reminder holds, for the closed field list.
    struct Values {
        let title: String?
        let location: String?
        let notes: String?
        let url: URL?
        let timeZone: TimeZone?
        let start: DateComponents?
        let due: DateComponents?
        let priority: Int
        let isCompleted: Bool
        let completionDate: Date?
        let alarms: [AlarmSnapshot]
        let rules: [EKRecurrenceRule]
        let calendarID: String?

        init(_ reminder: EKReminder) {
            title = reminder.title
            location = reminder.location
            notes = reminder.notes
            url = reminder.url
            timeZone = reminder.timeZone
            start = reminder.startDateComponents
            due = reminder.dueDateComponents
            priority = reminder.priority
            isCompleted = reminder.isCompleted
            completionDate = reminder.completionDate
            alarms = (reminder.alarms ?? []).map(AlarmSnapshot.init(from:))
            rules = (reminder.recurrenceRules ?? []).map(ReminderFieldCopy.copyRule)
            calendarID = reminder.calendar?.calendarIdentifier
        }
    }

    /// The fields whose value differs between `before` and `after`.
    static func changed(from before: Values, to after: Values) -> Set<Field> {
        var fields: Set<Field> = []
        if before.title != after.title { fields.insert(.title) }
        if before.location != after.location { fields.insert(.location) }
        if before.notes != after.notes { fields.insert(.notes) }
        if before.url != after.url { fields.insert(.url) }
        if before.timeZone != after.timeZone { fields.insert(.timeZone) }
        if before.start != after.start { fields.insert(.startDateComponents) }
        if before.due != after.due { fields.insert(.dueDateComponents) }
        if before.priority != after.priority { fields.insert(.priority) }
        if before.isCompleted != after.isCompleted { fields.insert(.isCompleted) }
        if before.completionDate != after.completionDate { fields.insert(.completionDate) }
        for kind in AlarmSnapshot.Kind.allCases
        where counts(before.alarms.filter { $0.kind == kind }) != counts(after.alarms.filter { $0.kind == kind }) {
            fields.insert(.alarms(kind))
        }
        if before.rules.map(ruleSignature).sorted() != after.rules.map(ruleSignature).sorted() { fields.insert(.recurrenceRules) }
        if before.calendarID != after.calendarID { fields.insert(.calendar) }
        return fields
    }

    /// Writes `wanted`'s value of each field in `fields` onto `target`, and nothing else. Throws
    /// `EventKitError.writeStoreLookupFailed` before writing anything when the write store cannot
    /// see the list the reminder moves to.
    static func apply(_ wanted: Values, fields: Set<Field>, to target: EKReminder, calendar lookup: (String) -> EKCalendar?) throws {
        var list: EKCalendar?
        if fields.contains(.calendar), let id = wanted.calendarID {
            guard let found = lookup(id) else { throw EventKitError.writeStoreLookupFailed(kind: "reminder list") }
            list = found
        }
        if fields.contains(.title) { target.title = wanted.title }
        if fields.contains(.location) { target.location = wanted.location }
        if fields.contains(.notes) { target.notes = wanted.notes }
        if fields.contains(.url) { target.url = wanted.url }
        if fields.contains(.priority) { target.priority = wanted.priority }
        if !fields.isDisjoint(with: [.startDateComponents, .dueDateComponents, .timeZone]) {
            ReminderDateSync.restore(target,
                                     start: fields.contains(.startDateComponents) ? wanted.start : target.startDateComponents,
                                     due: fields.contains(.dueDateComponents) ? wanted.due : target.dueDateComponents)
            if fields.contains(.timeZone) { target.timeZone = wanted.timeZone }
        }
        if fields.contains(.isCompleted) { target.isCompleted = wanted.isCompleted }
        if fields.contains(.completionDate) { target.completionDate = wanted.completionDate }
        for kind in AlarmSnapshot.Kind.allCases where fields.contains(.alarms(kind)) {
            AlarmSnapshot.restore(wanted.alarms, to: target, kind: kind)
        }
        if fields.contains(.recurrenceRules) {
            target.recurrenceRules = wanted.rules.isEmpty ? nil : wanted.rules.map(copyRule)
        }
        if let list { target.calendar = list }
    }

    private static func counts(_ snapshots: [AlarmSnapshot]) -> [AlarmSnapshot: Int] {
        snapshots.reduce(into: [:]) { $0[$1, default: 0] += 1 }
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

/// #459: a rename or recolor of a reminder list writes only the field this call changed (PR #507
/// round 1: a rename no longer writes back a color changed elsewhere, and the other way round).
enum ListFieldCopy {
    enum Field: String, CaseIterable, Hashable { case title, cgColor }

    static let fields = Field.allCases.map(\.rawValue)

    struct Values {
        let title: String
        let cgColor: CGColor?
        init(_ calendar: EKCalendar) {
            title = calendar.title
            cgColor = calendar.cgColor
        }
    }

    static func changed(from before: Values, to after: Values) -> Set<Field> {
        var fields: Set<Field> = []
        if before.title != after.title { fields.insert(.title) }
        if before.cgColor != after.cgColor { fields.insert(.cgColor) }
        return fields
    }

    static func apply(_ wanted: Values, fields: Set<Field>, to target: EKCalendar) {
        if fields.contains(.title) { target.title = wanted.title }
        if fields.contains(.cgColor) { target.cgColor = wanted.cgColor }
    }
}
