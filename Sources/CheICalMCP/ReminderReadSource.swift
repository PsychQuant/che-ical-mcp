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
    let calendarItemIdentifier: String
    let title: String?
    let notes: String?
    let isCompleted: Bool
    let priority: Int
    let calendar: List
    let dueDateComponents: DateComponents?
    let completionDate: Date?
    let creationDate: Date?
    let hasRecurrence: Bool
    let rules: [ReminderRecurrenceRuleValue]?
    let locationTrigger: LocationTrigger?

    init(id: String, title: String?, notes: String? = nil, isCompleted: Bool = false,
         priority: Int = 0, calendarTitle: String = "Reminders", dueDateComponents: DateComponents? = nil,
         completionDate: Date? = nil, creationDate: Date? = nil, hasRecurrence: Bool = false,
         rules: [ReminderRecurrenceRuleValue]? = nil, locationTrigger: LocationTrigger? = nil) {
        self.calendarItemIdentifier = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.priority = priority
        self.calendar = List(title: calendarTitle)
        self.dueDateComponents = dueDateComponents
        self.completionDate = completionDate
        self.creationDate = creationDate
        self.hasRecurrence = hasRecurrence
        self.rules = rules
        self.locationTrigger = locationTrigger
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
        self.init(id: reminder.calendarItemIdentifier, title: reminder.title, notes: reminder.notes,
                  isCompleted: reminder.isCompleted, priority: reminder.priority,
                  calendarTitle: reminder.calendar?.title ?? "", dueDateComponents: reminder.dueDateComponents,
                  completionDate: reminder.completionDate, creationDate: reminder.creationDate,
                  hasRecurrence: reminder.hasRecurrenceRules,
                  rules: reminder.recurrenceRules?.map(ReminderRecurrenceRuleValue.init(from:)),
                  locationTrigger: trigger)
    }

    var recurrenceMetadata: [String: Any] {
        reminderMetadata(hasRecurrence: hasRecurrence, rules: rules,
                         due: ReminderDueValue(components: dueDateComponents))
    }
}
