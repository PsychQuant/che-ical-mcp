import Foundation

struct ReminderCreateRequest: Sendable {
    let title: String
    var notes: String? = nil
    var dueDate: Date? = nil
    var priority = 0
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var recurrenceRule: RecurrenceRuleInput? = nil
    var locationTrigger: LocationTriggerInput? = nil
}
struct ReminderUpdateRequest: Sendable {
    let identifier: String
    var title: String? = nil
    var notes: String? = nil
    var dueDate: Date? = nil
    var priority: Int? = nil
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var locationTrigger: LocationTriggerInput? = nil
    var clearLocationTrigger = false
    var clearDueDate = false
}
/// #227: `update_reminder` reports how the start date and absolute alarms followed the due date.
struct ReminderUpdateResult: Sendable {
    let reminder: ReminderWriteSnapshot
    /// `nil` when the update did not touch the due date.
    let dateSync: ReminderDateSync.Report?
}
protocol ReminderWriteSource: Sendable {
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot
}
extension EventKitManager: ReminderWriteSource {
    func createReminder(_ request: ReminderCreateRequest) async throws -> CreateReminderResult {
        try await createReminder(title: request.title, notes: request.notes, dueDate: request.dueDate,
                                 priority: request.priority, calendarName: request.calendarName,
                                 calendarSource: request.calendarSource, recurrenceRule: request.recurrenceRule,
                                 locationTrigger: request.locationTrigger)
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        try await updateReminder(identifier: request.identifier, title: request.title, notes: request.notes,
                                 dueDate: request.dueDate, priority: request.priority,
                                 calendarName: request.calendarName, calendarSource: request.calendarSource,
                                 locationTrigger: request.locationTrigger, clearLocationTrigger: request.clearLocationTrigger,
                                 clearDueDate: request.clearDueDate)
    }
}
