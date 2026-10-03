import Foundation
struct EventCopyValue: Sendable {
    let eventIdentifier: String?
    let title: String?
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
}
extension EventKitManager: EventCopySource {
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        let event = try await copyEvent(identifier: identifier, toCalendarName: toCalendarName,
                                        toCalendarSource: toCalendarSource, deleteOriginal: deleteOriginal)
        return EventCopyValue(eventIdentifier: event.eventIdentifier, title: event.title)
    }
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue {
        let moved = try await moveEvent(identifier: identifier, occurrenceDate: occurrenceDate, span: span,
                                        toCalendarName: toCalendarName, toCalendarSource: toCalendarSource)
        return EventMoveValue(result: moved.result, title: moved.title)
    }
}
