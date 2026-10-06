import EventKit
import Foundation

/// Only the list/search surface; deliberately separate from cleanup's protocol.
protocol ReminderReadSource: Sendable {
    func listReminderPage(completed: Bool?, calendarName: String?, calendarSource: String?, query: ReminderPageQuery) async throws -> ReminderPage
    func searchReminderPage(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?, query: ReminderPageQuery) async throws -> ReminderPage
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot]
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot]
}

/// Value copy made inside the manager actor, before mutable EventKit objects escape.
struct ReminderReadSnapshot: Sendable {
    struct List: Sendable { let title: String }
    struct LocationTrigger: Sendable {
        let title: String
        let latitude: Double?
        let longitude: Double?
        let radius: Double?
        let proximity: String?
        var dictionary: [String: Any] {
            var value: [String: Any] = ["title": title]
            if let latitude { value["latitude"] = latitude }
            if let longitude { value["longitude"] = longitude }
            if let radius { value["radius"] = radius }
            if let proximity { value["proximity"] = proximity }
            return value
        }
    }
    /// A time-based alarm (#231). Location alarms are `locationTrigger`, not one of these.
    enum Alarm: Equatable, Sendable {
        /// EventKit's `relativeOffset`: negative is before the due date.
        case relative(seconds: TimeInterval)
        case absolute(Date)

        /// The alarms as the read output lists them. A relative offset that is not
        /// finite is left out: JSON cannot encode it, and `formatJSON` would fail the
        /// whole response. The rest are sorted with `listedBefore`.
        static func listed(_ alarms: [Alarm]) -> [Alarm] {
            alarms.filter {
                if case .relative(let seconds) = $0 { return seconds.isFinite }
                return true
            }.sorted(by: listedBefore)
        }

        /// `EKCalendarItem.alarms` order changes between process launches, so the read
        /// output sorts: absolute alarms by date, then relative alarms earliest first.
        static func listedBefore(_ lhs: Alarm, _ rhs: Alarm) -> Bool {
            switch (lhs, rhs) {
            case let (.absolute(a), .absolute(b)): return a < b
            case let (.relative(a), .relative(b)): return a < b
            case (.absolute, .relative): return true
            case (.relative, .absolute): return false
            }
        }
    }
    let calendarItemIdentifier: String
    let title: String?
    let notes: String?
    let isCompleted: Bool
    let priority: Int
    let calendar: List
    let dueDateComponents: DateComponents?
    let startDateComponents: DateComponents?
    let completionDate: Date?
    let creationDate: Date?
    let hasRecurrence: Bool
    let rules: [ReminderRecurrenceRuleValue]?
    let locationTrigger: LocationTrigger?
    let alarms: [Alarm]

    init(id: String, title: String?, notes: String? = nil, isCompleted: Bool = false,
         priority: Int = 0, calendarTitle: String = "Reminders", dueDateComponents: DateComponents? = nil,
         startDateComponents: DateComponents? = nil,
         completionDate: Date? = nil, creationDate: Date? = nil, hasRecurrence: Bool = false,
         rules: [ReminderRecurrenceRuleValue]? = nil, locationTrigger: LocationTrigger? = nil,
         alarms: [Alarm] = []) {
        self.calendarItemIdentifier = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.priority = priority
        self.calendar = List(title: calendarTitle)
        self.dueDateComponents = dueDateComponents
        self.startDateComponents = startDateComponents
        self.completionDate = completionDate
        self.creationDate = creationDate
        self.hasRecurrence = hasRecurrence
        self.rules = rules
        self.locationTrigger = locationTrigger
        self.alarms = alarms
    }

    init(from reminder: EKReminder) {
        var trigger: LocationTrigger?
        if let alarm = reminder.alarms?.first(where: { $0.structuredLocation != nil }),
           let location = alarm.structuredLocation {
            let proximity: String?
            switch alarm.proximity {
            case .enter: proximity = "enter"
            case .leave: proximity = "leave"
            default: proximity = nil
            }
            trigger = LocationTrigger(title: location.title ?? "",
                                      latitude: location.geoLocation?.coordinate.latitude,
                                      longitude: location.geoLocation?.coordinate.longitude,
                                      radius: location.radius > 0 ? location.radius : nil,
                                      proximity: proximity)
        }
        // A location alarm reads back with absoluteDate nil and relativeOffset 0, so
        // it has to be set aside before the absolute/relative split (#231).
        let alarms = Alarm.listed((reminder.alarms ?? []).compactMap { alarm in
            guard alarm.structuredLocation == nil else { return nil }
            if let date = alarm.absoluteDate { return .absolute(date) }
            return .relative(seconds: alarm.relativeOffset)
        })
        self.init(id: reminder.calendarItemIdentifier, title: reminder.title, notes: reminder.notes,
                  isCompleted: reminder.isCompleted, priority: reminder.priority,
                  calendarTitle: reminder.calendar?.title ?? "", dueDateComponents: reminder.dueDateComponents,
                  startDateComponents: reminder.startDateComponents,
                  completionDate: reminder.completionDate, creationDate: reminder.creationDate,
                  hasRecurrence: reminder.hasRecurrenceRules,
                  rules: reminder.recurrenceRules?.map(ReminderRecurrenceRuleValue.init(from:)),
                  locationTrigger: trigger, alarms: alarms)
    }

    var recurrenceMetadata: [String: Any] {
        reminderMetadata(hasRecurrence: hasRecurrence, rules: rules,
                         due: ReminderDueValue(components: dueDateComponents))
    }
}
