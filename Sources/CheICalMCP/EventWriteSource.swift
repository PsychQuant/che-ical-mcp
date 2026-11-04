import EventKit
import Foundation

/// The fields of an `update_event` call, as `EventKitManager.updateEvent` takes them.
struct EventUpdateRequest: Sendable {
    let identifier: String
    var title: String? = nil
    var startDate: Date? = nil
    var endDate: Date? = nil
    var notes: String? = nil
    var location: String? = nil
    var url: String? = nil
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var isAllDay: Bool? = nil
    var alarmOffsets: [Int]? = nil
    var recurrenceRule: RecurrenceRuleInput? = nil
    var clearRecurrence = false
    var structuredLocation: StructuredLocationInput? = nil
    var span: EKSpan = .thisEvent
    var occurrenceDate: Date? = nil
    var applyToAll = false
    var timezone: TimeZone? = nil
    var clearTimezone = false
}

/// The saved event, as the write handlers read it for their response.
struct EventWriteValue: Sendable, Equatable {
    let eventIdentifier: String?
    let title: String?
    let isAllDay: Bool
    let startDate: Date
    let endDate: Date
}

/// #268: narrow seam for the event write handlers (CLAUDE.md "Test Seam Convention"), so a test
/// can return a saved event whose identifier differs from the one the call named.
protocol EventWriteSource: Sendable {
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue
}

extension EventWriteValue {
    init(_ event: EKEvent) {
        self.init(eventIdentifier: event.eventIdentifier, title: event.title, isAllDay: event.isAllDay,
                  startDate: event.startDate, endDate: event.endDate)
    }
}

extension EventKitManager: EventWriteSource {
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        let event = try await updateEvent(
            identifier: request.identifier, title: request.title,
            startDate: request.startDate, endDate: request.endDate,
            notes: request.notes, location: request.location, url: request.url,
            calendarName: request.calendarName, calendarSource: request.calendarSource,
            isAllDay: request.isAllDay, alarmOffsets: request.alarmOffsets,
            recurrenceRule: request.recurrenceRule, clearRecurrence: request.clearRecurrence,
            structuredLocation: request.structuredLocation, span: request.span,
            occurrenceDate: request.occurrenceDate, applyToAll: request.applyToAll,
            timezone: request.timezone, clearTimezone: request.clearTimezone)
        return EventWriteValue(event)
    }
}
