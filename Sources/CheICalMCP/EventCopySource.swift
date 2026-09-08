struct EventCopyValue: Sendable {
    let eventIdentifier: String?
    let title: String?
}
protocol EventCopySource: Sendable {
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue
}
extension EventKitManager: EventCopySource {
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        let event = try await copyEvent(identifier: identifier, toCalendarName: toCalendarName,
                                        toCalendarSource: toCalendarSource, deleteOriginal: deleteOriginal)
        return EventCopyValue(eventIdentifier: event.eventIdentifier, title: event.title)
    }
}
