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

    /// #604: the same three reads with a `calendar_id`. The manager answers them; a source that does
    /// not (a test double) gets the default below, which forwards a call without an id to the read
    /// above and refuses one with an id.
    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         calendarID: String?, pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info>
    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?, calendarID: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info>
    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             calendarID: String?, excludeEventId: String?) async throws -> [EventReadValue]
}

extension EventRangeReadSource {
    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         calendarID: String?, pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        guard calendarID == nil else { throw ToolError.invalidParameter(Self.calendarIDUnsupported) }
        return try await listEventValues(startDate: startDate, endDate: endDate, calendarName: calendarName,
                                         calendarSource: calendarSource, pick: pick)
    }

    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?, calendarID: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        guard calendarID == nil else { throw ToolError.invalidParameter(Self.calendarIDUnsupported) }
        return try await searchEventValues(keywords: keywords, matchMode: matchMode, startDate: startDate, endDate: endDate,
                                           calendarName: calendarName, calendarSource: calendarSource, pick: pick)
    }

    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             calendarID: String?, excludeEventId: String?) async throws -> [EventReadValue] {
        guard calendarID == nil else { throw ToolError.invalidParameter(Self.calendarIDUnsupported) }
        return try await checkConflictValues(startDate: startDate, endDate: endDate, calendarName: calendarName,
                                             calendarSource: calendarSource, excludeEventId: excludeEventId)
    }

    static var calendarIDUnsupported: String { "calendar_id is not supported by this source." }
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

    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         calendarID: String?, pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        let events = try await listEvents(startDate: startDate, endDate: endDate, calendarName: calendarName,
                                          calendarSource: calendarSource, calendarID: calendarID)
        return EventRowsPicked.picking(events, pick)
    }

    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?, calendarID: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        let events = try await searchEvents(keywords: keywords, matchMode: matchMode, startDate: startDate, endDate: endDate,
                                            calendarName: calendarName, calendarSource: calendarSource, calendarID: calendarID)
        return EventRowsPicked.picking(events, pick)
    }

    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             calendarID: String?, excludeEventId: String?) async throws -> [EventReadValue] {
        try await checkConflicts(startDate: startDate, endDate: endDate, calendarName: calendarName,
                                 calendarSource: calendarSource, calendarID: calendarID, excludeEventId: excludeEventId)
            .map(EventReadValue.init)
    }

    /// #604: each row says which list it came from, so event calendars and reminder lists in one
    /// answer are told apart.
    func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue] {
        func values(_ type: EKEntityType, _ name: String) async throws -> [CalendarReadValue] {
            try await listCalendars(for: type).map { CalendarReadValue($0, entityTypes: [name]) }
        }
        switch entityType {
        case .event?: return try await values(.event, "event")
        case .reminder?: return try await values(.reminder, "reminder")
        default: return try await values(.event, "event") + values(.reminder, "reminder")
        }
    }
}
