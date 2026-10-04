import Foundation
struct EventCopyValue: Sendable {
    let eventIdentifier: String?
    let title: String?
    /// Set when copy_event moved the event (`delete_original`), #226.
    var move: EventMoveResult? = nil
}
/// #226: one move's outcome plus the event title for the response.
struct EventMoveValue: Sendable {
    let result: EventMoveResult
    let title: String?
}
protocol EventCopySource: Sendable {
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue
    /// The event's own time zone, for parsing occurrence dates the way `delete_event` does.
    func eventTimeZone(identifier: String) async -> TimeZone?
}
extension EventKitManager: EventCopySource {
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        if deleteOriginal {
            let moved = try await moveEventForCopyTool(identifier: identifier, toCalendarName: toCalendarName,
                                                       toCalendarSource: toCalendarSource)
            return EventCopyValue(eventIdentifier: moved.result.eventIdentifier, title: moved.title, move: moved.result)
        }
        let event = try await copyEvent(identifier: identifier, toCalendarName: toCalendarName,
                                        toCalendarSource: toCalendarSource)
        return EventCopyValue(eventIdentifier: event.eventIdentifier, title: event.title)
    }
    func eventTimeZone(identifier: String) async -> TimeZone? {
        getEventTimezone(identifier: identifier)
    }
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue {
        let moved = try await moveEvent(identifier: identifier, occurrenceDate: occurrenceDate, span: span,
                                        toCalendarName: toCalendarName, toCalendarSource: toCalendarSource)
        return EventMoveValue(result: moved.result, title: moved.title)
    }
}
