import EventKit

/// Test seam for #332: the two range reads whose answer `list_events` and `search_events` shape, so
/// a handler test reads the response (`event_count`, `truncated`, `default_limit`) instead of the
/// handler's source. Production passes nothing and gets `EventKitManager.shared`.
protocol EventRangeReadSource: Sendable {
    func listEvents(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?) async throws -> [EKEvent]
    func searchEvents(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                      calendarName: String?, calendarSource: String?) async throws -> [EKEvent]
}

extension EventKitManager: EventRangeReadSource {}
