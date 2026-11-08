import Foundation

struct ReminderCreateRequest: Sendable {
    let title: String
    var notes: String? = nil
    /// #267: a day (bare `YYYY-MM-DD`) or an instant.
    var due: ReminderDueInput? = nil
    var priority = 0
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var recurrenceRule: RecurrenceRuleInput? = nil
    var locationTrigger: LocationTriggerInput? = nil
    /// #333: relative alarms, minutes before the due date (`alarms_minutes_offsets`).
    var alarmOffsets: [Int]? = nil
}
struct ReminderUpdateRequest: Sendable {
    let identifier: String
    var title: String? = nil
    var notes: String? = nil
    /// #267: a day (bare `YYYY-MM-DD`) or an instant.
    var due: ReminderDueInput? = nil
    var priority: Int? = nil
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var locationTrigger: LocationTriggerInput? = nil
    var clearLocationTrigger = false
    var clearDueDate = false
    /// #235: put the start date and absolute alarms onto the (new or current) due date.
    var realignToDue = false
    /// #333: replaces (or with `[]` clears) the relative alarms only; absolute and location alarms stay.
    var alarmOffsets: [Int]? = nil
    /// #354: replaces the reminder's recurrence rule (`recurrence`), or removes it (`clear_recurrence`).
    var recurrenceRule: RecurrenceRuleInput? = nil
    var clearRecurrence = false
}
/// #227: `update_reminder` reports how the start date and absolute alarms followed the due date.
struct ReminderUpdateResult: Sendable {
    let reminder: ReminderWriteSnapshot
    /// `nil` when the update did not touch the due date.
    let dateSync: ReminderDateSync.Report?
    /// #333: the relative alarms read off the saved reminder (minutes before), when the request
    /// carried `alarmOffsets`; nil otherwise.
    var storedRelativeAlarms: [Double]? = nil
    /// PR #415 verify round 1: set when the update left relative alarms on a reminder without a
    /// timed due (`ReminderRelativeAlarms.leftoverNote`).
    var leftoverAlarmsNote: String? = nil
    /// #433: the update touched the alarms or the due date and the earliest alarm is off the due time.
    var listShowsAlarmTime = false
    /// #354: the rule and due read off the saved reminder, when the request touched the rule.
    var recurrence: ReminderRecurrenceWrite.ReadBack? = nil
}
protocol ReminderWriteSource: Sendable {
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot
}
extension EventKitManager: ReminderWriteSource {
    func createReminder(_ request: ReminderCreateRequest) async throws -> CreateReminderResult {
        try await createReminder(title: request.title, notes: request.notes, due: request.due,
                                 priority: request.priority, calendarName: request.calendarName,
                                 calendarSource: request.calendarSource, alarmOffsets: request.alarmOffsets,
                                 recurrenceRule: request.recurrenceRule, locationTrigger: request.locationTrigger)
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        try await updateReminder(identifier: request.identifier, title: request.title, notes: request.notes,
                                 due: request.due, priority: request.priority,
                                 calendarName: request.calendarName, calendarSource: request.calendarSource,
                                 locationTrigger: request.locationTrigger, clearLocationTrigger: request.clearLocationTrigger,
                                 clearDueDate: request.clearDueDate, realignToDue: request.realignToDue,
                                 alarmOffsets: request.alarmOffsets,
                                 recurrenceRule: request.recurrenceRule, clearRecurrence: request.clearRecurrence)
    }
}
