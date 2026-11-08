import EventKit

/// Test seam for #332: the range reads whose answer `list_events`, `search_events`,
/// `list_events_quick` and `check_conflicts` shape, so a handler test reads the response
/// (`event_count`, `truncated`, `default_limit`) instead of the handler's source. Production passes
/// nothing and gets `EventKitManager.shared`.
///
/// #490: each read returns `EventReadValue`s the manager copies on its actor, never `EKEvent`s, so
/// the server's nonisolated handlers read no EventKit object. PR #495 round 1: the list and search
/// reads take the handler's `pick` over light keys and copy whole only the rows it keeps
/// (`EventRowsPicked.picking`); the conflicts read keeps every row, so it copies them all.
protocol EventRangeReadSource: Sendable {
    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info>
    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info>
    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue]
}

/// #490: the read `list_calendars` shapes, as values copied on the manager's actor.
protocol CalendarListSource: Sendable {
    func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue]
}

extension EventKitManager: EventRangeReadSource, CalendarListSource {
    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        let events = try await listEvents(startDate: startDate, endDate: endDate, calendarName: calendarName,
                                          calendarSource: calendarSource)
        return EventRowsPicked.picking(events, pick)
    }

    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        let events = try await searchEvents(keywords: keywords, matchMode: matchMode, startDate: startDate, endDate: endDate,
                                            calendarName: calendarName, calendarSource: calendarSource)
        return EventRowsPicked.picking(events, pick)
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
