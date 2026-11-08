import EventKit

/// Test seam for #332: the range reads whose answer `list_events`, `search_events`,
/// `list_events_quick` and `check_conflicts` shape, so a handler test reads the response
/// (`event_count`, `truncated`, `default_limit`) instead of the handler's source. Production passes
/// nothing and gets `EventKitManager.shared`.
///
/// #490: each read returns `EventReadValue`s the manager copies on its actor, never `EKEvent`s, so
/// the server's nonisolated handlers read no EventKit object.
protocol EventRangeReadSource: Sendable {
    func listEventValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?) async throws -> [EventReadValue]
    func searchEventValues(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                           calendarName: String?, calendarSource: String?) async throws -> [EventReadValue]
    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue]
}

/// #490: the read `list_calendars` shapes, as values copied on the manager's actor.
protocol CalendarListSource: Sendable {
    func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue]
}

extension EventKitManager: EventRangeReadSource, CalendarListSource {
    func listEventValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?) async throws -> [EventReadValue] {
        try await listEvents(startDate: startDate, endDate: endDate, calendarName: calendarName, calendarSource: calendarSource)
            .map(EventReadValue.init)
    }

    func searchEventValues(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                           calendarName: String?, calendarSource: String?) async throws -> [EventReadValue] {
        try await searchEvents(keywords: keywords, matchMode: matchMode, startDate: startDate, endDate: endDate,
                               calendarName: calendarName, calendarSource: calendarSource)
            .map(EventReadValue.init)
    }

    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue] {
        try await checkConflicts(startDate: startDate, endDate: endDate, calendarName: calendarName,
                                 calendarSource: calendarSource, excludeEventId: excludeEventId)
            .map(EventReadValue.init)
    }

    func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue] {
        try await listCalendars(for: entityType).map(CalendarReadValue.init)
    }
}
