import CoreLocation
import EventKit
import Foundation
import MCP

/// Safely extract a Date from DateComponents, ignoring week-based fields
/// that EventKit may add (weekOfYear, yearForWeekOfYear, weekday) which can
/// conflict with day-based fields and cause +7 day date shifts. (#18)
func safeDateFromComponents(_ components: DateComponents?) -> Date? {
    guard let dc = components else { return nil }

    var clean = DateComponents()
    clean.year = dc.year
    clean.month = dc.month
    clean.day = dc.day
    clean.hour = dc.hour
    clean.minute = dc.minute
    clean.second = dc.second
    clean.timeZone = dc.timeZone

    // If we have enough day-based fields, use them
    if dc.year != nil && dc.month != nil && dc.day != nil {
        return Calendar.current.date(from: clean)
    }

    // Fallback: if no day-based fields, use the original .date
    return dc.date
}

/// MCP Server for EventKit integration
class CheICalMCPServer {
    private let server: Server
    private let transport: StdioTransport
    private let eventKitManager = EventKitManager.shared
    private let dateFormatter: ISO8601DateFormatter

    /// Local time formatter for user-friendly display
    private let localDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Format a date as local time in a specific timezone
    private func formatLocal(_ date: Date, in tz: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = tz ?? TimeZone.current
        return formatter.string(from: date)
    }

    /// All available tools
    private let tools: [Tool]

    init() async throws {
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        // Define all tools
        tools = Self.defineTools()

        // Create server with tools capability
        server = Server(
            name: AppVersion.name,
            version: AppVersion.current,
            capabilities: .init(tools: .init())
        )

        transport = StdioTransport()

        // Register handlers
        await registerHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    private static func defineTools() -> [Tool] {
        [
            // Calendar Tools
            Tool(
                name: "list_calendars",
                description: "List all available calendars. Returns both event calendars and reminder lists.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("Filter by type: 'event' or 'reminder'. If not provided, returns all calendars.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_calendar",
                description: "Create a new calendar or reminder list.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("The name of the calendar")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string("Type of calendar: 'event' or 'reminder'")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("Optional hex color code (e.g., '#FF5733')")
                        ])
                    ]),
                    "required": .array([.string("title"), .string("type")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "delete_calendar",
                description: "Delete a calendar by its identifier.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The calendar identifier")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "update_calendar",
                description: "Update a calendar's properties (rename or change color).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The calendar identifier")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("New calendar name")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("New hex color code (e.g., '#FF5733')")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),

            // Event Tools
            Tool(
                name: "list_events",
                description: "List calendar events in a date range with optional filtering, sorting, and limiting. Supports flexible date formats: ISO8601 (2026-01-30T00:00:00+08:00), datetime (2026-01-30T00:00:00), date only (2026-01-30), or time only (14:00).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "start_date": .object([
                            "type": .string("string"),
                            "description": .string("Start date (e.g., 2026-01-30T00:00:00+08:00 or 2026-01-30)")
                        ]),
                        "end_date": .object([
                            "type": .string("string"),
                            "description": .string("End date (e.g., 2026-01-30T23:59:59+08:00 or 2026-01-30)")
                        ]),
                        "calendar_name": .object([
                            "type": .string("string"),
                            "description": .string("Optional calendar name to filter by")
                        ]),
                        "calendar_source": .object([
                            "type": .string("string"),
                            "description": .string("Calendar source name (e.g., 'iCloud', 'Google', 'Exchange'). Required when multiple calendars share the same name.")
                        ]),
                        "filter": .object([
                            "type": .string("string"),
                            "enum": .array([.string("all"), .string("past"), .string("future"), .string("all_day")]),
                            "description": .string("Filter events: 'all' (default), 'past' (ended before now), 'future' (starts after now), 'all_day' (all-day events only)")
                        ]),
                        "sort": .object([
                            "type": .string("string"),
                            "enum": .array([.string("asc"), .string("desc")]),
                            "description": .string("Sort by start date: 'asc' (default, earliest first), 'desc' (latest first)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of events to return")
                        ])
                    ]),
                    "required": .array([.string("start_date"), .string("end_date")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_event",
                description: "Create a new calendar event with optional reminders and recurrence.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string"), "description": .string("Event title")]),
                        "start_time": .object(["type": .string("string"), "description": .string("Start time in ISO8601 format with timezone (e.g., 2026-01-30T14:00:00+08:00)")]),
                        "end_time": .object(["type": .string("string"), "description": .string("End time in ISO8601 format with timezone (e.g., 2026-01-30T15:00:00+08:00)")]),
                        "notes": .object(["type": .string("string"), "description": .string("Optional event notes")]),
                        "location": .object(["type": .string("string"), "description": .string("Optional event location")]),
                        "url": .object(["type": .string("string"), "description": .string("Optional event URL")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Target calendar name (use list_calendars to see available options)")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "all_day": .object(["type": .string("boolean"), "description": .string("Whether this is an all-day event")]),
                        "alarms_minutes_offsets": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                            "description": .string("List of minutes before the event to trigger reminders")
                        ]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Recurrence rule. Example: {\"frequency\": \"weekly\", \"interval\": 1, \"days_of_week\": [2,6]} for every Mon & Fri."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1). E.g., interval=2 with frequency=weekly means every other week.")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). Mutually exclusive with occurrence_count.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences. Mutually exclusive with end_date.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("For weekly: days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday)")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("For monthly: days of month to repeat (1-31)")
                                ])
                            ]),
                            "required": .array([.string("frequency")])
                        ]),
                        "timezone": .object(["type": .string("string"), "description": .string("IANA timezone identifier for the event (e.g., 'Europe/Berlin', 'America/New_York'). Sets the event's display timezone in Calendar.app.")]),
                        "structured_location": .object([
                            "type": .string("object"),
                            "description": .string("Structured location with coordinates. If provided, overrides the 'location' text field."),
                            "properties": .object([
                                "title": .object(["type": .string("string"), "description": .string("Location name (e.g., 'Office', 'Home')")]),
                                "latitude": .object(["type": .string("number"), "description": .string("Latitude coordinate")]),
                                "longitude": .object(["type": .string("number"), "description": .string("Longitude coordinate")]),
                                "radius": .object(["type": .string("number"), "description": .string("Radius in meters (default 100)")])
                            ]),
                            "required": .array([.string("title")])
                        ])
                    ]),
                    "required": .array([.string("title"), .string("start_time"), .string("end_time"), .string("calendar_name")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "update_event",
                description: "Update an existing calendar event. When changing the event date, providing only start_time will automatically preserve the original duration. For recurring events, use 'span' to control whether changes apply to this occurrence, future occurrences, or all.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_id": .object(["type": .string("string"), "description": .string("The event identifier")]),
                        "title": .object(["type": .string("string"), "description": .string("New title")]),
                        "start_time": .object(["type": .string("string"), "description": .string("New start time in ISO8601 format (e.g., 2026-01-31T14:00:00+08:00). If only start_time is provided, the event duration is preserved automatically.")]),
                        "end_time": .object(["type": .string("string"), "description": .string("New end time in ISO8601 format (e.g., 2026-01-31T15:00:00+08:00). Provide this if you want to change the event duration.")]),
                        "notes": .object(["type": .string("string"), "description": .string("New notes")]),
                        "location": .object(["type": .string("string"), "description": .string("New location")]),
                        "all_day": .object(["type": .string("boolean"), "description": .string("Set to true for all-day events, false for timed events")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Move event to a different calendar")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Set or replace recurrence rule. Example: {\"frequency\": \"weekly\", \"interval\": 1, \"days_of_week\": [2,6]} for every Mon & Fri."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1)")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). Mutually exclusive with occurrence_count.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences. Mutually exclusive with end_date.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("For weekly: days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday)")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("For monthly: days of month to repeat (1-31)")
                                ])
                            ]),
                            "required": .array([.string("frequency")])
                        ]),
                        "alarms_minutes_offsets": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                            "description": .string("List of minutes before the event to trigger reminders. Replaces all existing alarms. Use empty array [] to remove all alarms.")
                        ]),
                        "clear_recurrence": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove recurrence rule from event")
                        ]),
                        "structured_location": .object([
                            "type": .string("object"),
                            "description": .string("Structured location with coordinates. If provided, overrides the 'location' text field."),
                            "properties": .object([
                                "title": .object(["type": .string("string"), "description": .string("Location name (e.g., 'Office', 'Home')")]),
                                "latitude": .object(["type": .string("number"), "description": .string("Latitude coordinate")]),
                                "longitude": .object(["type": .string("number"), "description": .string("Longitude coordinate")]),
                                "radius": .object(["type": .string("number"), "description": .string("Radius in meters (default 100)")])
                            ]),
                            "required": .array([.string("title")])
                        ]),
                        "timezone": .object(["type": .string("string"), "description": .string("IANA timezone identifier for the event (e.g., 'Europe/Berlin', 'America/New_York'). Sets the event's display timezone.")]),
                        "clear_timezone": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove per-event timezone (revert to system timezone)")
                        ]),
                        "span": .object([
                            "type": .string("string"),
                            "enum": .array([.string("this"), .string("future"), .string("all")]),
                            "description": .string("For recurring events: 'this' (default) updates only this occurrence, 'future' updates this and all future occurrences, 'all' updates the entire series")
                        ]),
                        "occurrence_date": .object([
                            "type": .string("string"),
                            "description": .string("For recurring events: the date of the specific occurrence to modify (e.g., '2026-03-28'). Required when span is 'this' or 'future' on recurring events.")
                        ])
                    ]),
                    "required": .array([.string("event_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "delete_event",
                description: "Delete a calendar event. For recurring events, use the 'span' parameter (not 'delete_scope') to control scope. When span is 'this' or 'future' on a recurring event, occurrence_date is required to identify the specific occurrence.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_id": .object(["type": .string("string"), "description": .string("The event identifier")]),
                        "span": .object([
                            "type": .string("string"),
                            "enum": .array([.string("this"), .string("future"), .string("all")]),
                            "description": .string("For recurring events: 'this' (default) deletes only this occurrence, 'future' deletes this and all future occurrences, 'all' deletes the entire recurring series")
                        ]),
                        "occurrence_date": .object([
                            "type": .string("string"),
                            "description": .string("For recurring events: the date of the specific occurrence to act on (e.g., '2026-03-28' or '2026-03-28T09:30:00+08:00'). Required when span is 'this' or 'future' on recurring events.")
                        ])
                    ]),
                    "required": .array([.string("event_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Undo/Redo Tools
            Tool(
                name: "undo",
                description: "Undo the most recent calendar or reminder operation. Returns what was undone. Only works for operations in the current server session.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "redo",
                description: "Redo the last undone operation. Only available after an undo.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "undo_history",
                description: "List undoable operations with timestamps. Shows the undo stack (newest first) and redo stack.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of entries to return (default: 10)")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),

            // Reminder Tools
            Tool(
                name: "list_reminders",
                description: "List reminders from the Reminders app with optional filtering, sorting, and limiting.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "completed": .object(["type": .string("boolean"), "description": .string("Legacy filter: true=completed, false=incomplete, omit=all. Prefer using 'filter' parameter instead.")]),
                        "filter": .object([
                            "type": .string("string"),
                            "enum": .array([.string("all"), .string("incomplete"), .string("completed"), .string("overdue")]),
                            "description": .string("Filter reminders: 'all' (default), 'incomplete', 'completed', 'overdue' (incomplete with past due date). Takes priority over 'completed' parameter.")
                        ]),
                        "sort": .object([
                            "type": .string("string"),
                            "enum": .array([.string("due_date"), .string("creation_date"), .string("priority"), .string("title")]),
                            "description": .string("Sort by: 'due_date' (default, nulls last), 'creation_date', 'priority' (high→low), 'title' (alphabetical)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of reminders to return")
                        ]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional reminder list name")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_reminder",
                description: "Create a new reminder.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string"), "description": .string("Reminder title")]),
                        "notes": .object(["type": .string("string"), "description": .string("Optional notes")]),
                        "due_date": .object(["type": .string("string"), "description": .string("Optional due date in ISO8601 format with timezone (e.g., 2026-01-30T17:00:00+08:00)")]),
                        "priority": .object(["type": .string("integer"), "description": .string("Priority: 0=none, 1=high, 5=medium, 9=low")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Target reminder list name (use list_calendars with type='reminder' to see available options)")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Recurrence rule. Example: {\"frequency\": \"daily\"} for daily reminder."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1)")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). Mutually exclusive with occurrence_count.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences. Mutually exclusive with end_date.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("For weekly: days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday)")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("For monthly: days of month to repeat (1-31)")
                                ])
                            ]),
                            "required": .array([.string("frequency")])
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Tags for the reminder (stored as #hashtag text in notes, searchable via MCP). Example: [\"grocery\", \"urgent\"]")
                        ]),
                        "location_trigger": .object([
                            "type": .string("object"),
                            "description": .string("Location-based trigger. Reminder fires when entering or leaving the geofence."),
                            "properties": .object([
                                "title": .object(["type": .string("string"), "description": .string("Location name (e.g., 'Home', 'Office')")]),
                                "latitude": .object(["type": .string("number"), "description": .string("Latitude coordinate")]),
                                "longitude": .object(["type": .string("number"), "description": .string("Longitude coordinate")]),
                                "radius": .object(["type": .string("number"), "description": .string("Geofence radius in meters (default 100)")]),
                                "proximity": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("enter"), .string("leave")]),
                                    "description": .string("When to trigger: 'enter' when arriving, 'leave' when departing")
                                ])
                            ]),
                            "required": .array([.string("title"), .string("latitude"), .string("longitude"), .string("proximity")])
                        ])
                    ]),
                    "required": .array([.string("title"), .string("calendar_name")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "update_reminder",
                description: "Update an existing reminder.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminder_id": .object(["type": .string("string"), "description": .string("The reminder identifier")]),
                        "title": .object(["type": .string("string"), "description": .string("New title")]),
                        "notes": .object(["type": .string("string"), "description": .string("New notes")]),
                        "due_date": .object(["type": .string("string"), "description": .string("New due date")]),
                        "clear_due_date": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove due date from reminder")
                        ]),
                        "priority": .object(["type": .string("integer"), "description": .string("New priority")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Move reminder to a different list")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")]),
                        "location_trigger": .object([
                            "type": .string("object"),
                            "description": .string("Location-based trigger. Reminder fires when entering or leaving the geofence."),
                            "properties": .object([
                                "title": .object(["type": .string("string"), "description": .string("Location name (e.g., 'Home', 'Office')")]),
                                "latitude": .object(["type": .string("number"), "description": .string("Latitude coordinate")]),
                                "longitude": .object(["type": .string("number"), "description": .string("Longitude coordinate")]),
                                "radius": .object(["type": .string("number"), "description": .string("Geofence radius in meters (default 100)")]),
                                "proximity": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("enter"), .string("leave")]),
                                    "description": .string("When to trigger: 'enter' when arriving, 'leave' when departing")
                                ])
                            ]),
                            "required": .array([.string("title"), .string("latitude"), .string("longitude"), .string("proximity")])
                        ]),
                        "clear_location_trigger": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove location trigger from reminder")
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Replace existing tags with these new tags (stored as #hashtag text in notes). Example: [\"grocery\", \"urgent\"]")
                        ]),
                        "clear_tags": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove all tags from reminder")
                        ])
                    ]),
                    "required": .array([.string("reminder_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "complete_reminder",
                description: "Mark a reminder as completed or incomplete.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminder_id": .object(["type": .string("string"), "description": .string("The reminder identifier")]),
                        "completed": .object(["type": .string("boolean"), "description": .string("true=completed, false=incomplete")])
                    ]),
                    "required": .array([.string("reminder_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "delete_reminder",
                description: "Delete a reminder.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminder_id": .object(["type": .string("string"), "description": .string("The reminder identifier")])
                    ]),
                    "required": .array([.string("reminder_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "search_reminders",
                description: "Search reminders by keyword(s) in title or notes, or filter by tag. Supports single keyword or multiple keywords with AND/OR matching.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "keyword": .object(["type": .string("string"), "description": .string("Single search keyword (case-insensitive). Use this OR keywords, not both.")]),
                        "keywords": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Multiple search keywords (use with match_mode). Example: [\"grocery\", \"urgent\"]")
                        ]),
                        "match_mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("any"), .string("all")]),
                            "description": .string("'any' = OR (matches if ANY keyword found, default), 'all' = AND (matches only if ALL keywords found)")
                        ]),
                        "tag": .object(["type": .string("string"), "description": .string("Filter by tag (without # prefix). Example: \"grocery\"")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional reminder list name to filter by")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")]),
                        "completed": .object(["type": .string("boolean"), "description": .string("Filter: true=completed, false=incomplete, omit=all")])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),

            // New Feature Tools

            // Feature 2: Search Events (enhanced with multi-keyword support)
            Tool(
                name: "search_events",
                description: "Search events by keyword(s) in title, notes, or location. Supports single keyword or multiple keywords with AND/OR matching. Without date range, defaults to ±2 years from today. Tip: To find past events beyond 2 years, always specify start_date. The response includes searched_range so you can verify coverage.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "keyword": .object(["type": .string("string"), "description": .string("Single search keyword (case-insensitive). Use this OR keywords, not both.")]),
                        "keywords": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Multiple search keywords (use with match_mode). Example: [\"meeting\", \"project\"]")
                        ]),
                        "match_mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("any"), .string("all")]),
                            "description": .string("'any' = OR (matches if ANY keyword found, default), 'all' = AND (matches only if ALL keywords found)")
                        ]),
                        "start_date": .object(["type": .string("string"), "description": .string("Optional start date in ISO8601 format with timezone (e.g., 2026-01-01T00:00:00+08:00)")]),
                        "end_date": .object(["type": .string("string"), "description": .string("Optional end date in ISO8601 format with timezone (e.g., 2026-12-31T23:59:59+08:00)")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional calendar name to filter by")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),

            // Feature 3: Quick Time Range
            Tool(
                name: "list_events_quick",
                description: "List events with quick time range shortcuts. Supports international week definitions.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "range": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("today"), .string("tomorrow"),
                                .string("this_week"), .string("next_week"),
                                .string("this_month"), .string("next_7_days"), .string("next_30_days")
                            ]),
                            "description": .string("Quick time range shortcut")
                        ]),
                        "week_starts_on": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("system"), .string("monday"), .string("sunday"), .string("saturday")
                            ]),
                            "description": .string("First day of week for this_week/next_week calculations. 'system' uses locale settings (default), 'monday' for ISO 8601/Europe/Asia, 'sunday' for US/Japan, 'saturday' for Middle East.")
                        ]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional calendar name to filter by")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")])
                    ]),
                    "required": .array([.string("range")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),

            // Feature 4: Batch Create Events
            Tool(
                name: "create_events_batch",
                description: "PREFERRED: Create multiple events in a single call. Use this instead of calling create_event multiple times - it's faster and more reliable. Returns detailed results for each event. Also returns similar_events hints showing existing events with similar titles, so you can reuse the correct calendar name and avoid duplicates.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "events": .object([
                            "type": .string("array"),
                            "description": .string("Array of event objects to create"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "title": .object(["type": .string("string")]),
                                    "start_time": .object(["type": .string("string")]),
                                    "end_time": .object(["type": .string("string")]),
                                    "notes": .object(["type": .string("string")]),
                                    "location": .object(["type": .string("string")]),
                                    "calendar_name": .object(["type": .string("string"), "description": .string("Target calendar name (required)")]),
                                    "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google')")]),
                                    "all_day": .object(["type": .string("boolean")]),
                                    "recurrence": .object([
                                        "type": .string("object"),
                                        "description": .string("Recurrence rule"),
                                        "properties": .object([
                                            "frequency": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")])]),
                                            "interval": .object(["type": .string("integer")]),
                                            "end_date": .object(["type": .string("string")]),
                                            "occurrence_count": .object(["type": .string("integer")]),
                                            "days_of_week": .object(["type": .string("array"), "items": .object(["type": .string("integer")])]),
                                            "days_of_month": .object(["type": .string("array"), "items": .object(["type": .string("integer")])])
                                        ]),
                                        "required": .array([.string("frequency")])
                                    ]),
                                    "timezone": .object(["type": .string("string"), "description": .string("IANA timezone identifier (e.g., 'Europe/Berlin')")]),
                                    "structured_location": .object([
                                        "type": .string("object"),
                                        "description": .string("Structured location with coordinates"),
                                        "properties": .object([
                                            "title": .object(["type": .string("string")]),
                                            "latitude": .object(["type": .string("number")]),
                                            "longitude": .object(["type": .string("number")]),
                                            "radius": .object(["type": .string("number")])
                                        ]),
                                        "required": .array([.string("title")])
                                    ])
                                ]),
                                "required": .array([.string("title"), .string("start_time"), .string("end_time"), .string("calendar_name")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("events")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),

            // Feature 5: Conflict Check
            Tool(
                name: "check_conflicts",
                description: "Check for overlapping events in a time range.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "start_time": .object(["type": .string("string"), "description": .string("Start time to check in ISO8601 format with timezone (e.g., 2026-01-30T14:00:00+08:00)")]),
                        "end_time": .object(["type": .string("string"), "description": .string("End time to check in ISO8601 format with timezone (e.g., 2026-01-30T15:00:00+08:00)")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional calendar name to filter by")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "exclude_event_id": .object(["type": .string("string"), "description": .string("Optional event ID to exclude from check (useful for updates)")])
                    ]),
                    "required": .array([.string("start_time"), .string("end_time")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),

            // Feature 6: Copy Event
            Tool(
                name: "copy_event",
                description: "Copy an event to another calendar. The original event is preserved.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_id": .object(["type": .string("string"), "description": .string("The event identifier to copy")]),
                        "target_calendar": .object(["type": .string("string"), "description": .string("Target calendar name to copy to")]),
                        "target_calendar_source": .object(["type": .string("string"), "description": .string("Target calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "delete_original": .object(["type": .string("boolean"), "description": .string("If true, delete the original event after copying (effectively a move)")])
                    ]),
                    "required": .array([.string("event_id"), .string("target_calendar")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),

            // Feature 7: Move Events Batch
            Tool(
                name: "move_events_batch",
                description: "PREFERRED: Move multiple events to another calendar in a single call. Use this instead of calling copy_event with delete_original multiple times - it's faster and more reliable. Returns detailed success/failure for each event.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Array of event IDs to move")
                        ]),
                        "target_calendar": .object(["type": .string("string"), "description": .string("Target calendar name to move events to")]),
                        "target_calendar_source": .object(["type": .string("string"), "description": .string("Target calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")])
                    ]),
                    "required": .array([.string("event_ids"), .string("target_calendar")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),

            // Feature 8: Delete Events Batch
            Tool(
                name: "delete_events_batch",
                description: "Delete multiple events. Two modes: (1) by event_ids - delete specific events, (2) by calendar + date range - delete all events matching criteria. Use dry_run=true (default) to preview before deleting.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Mode 1: Array of event identifiers to delete")
                        ]),
                        "calendar_name": .object([
                            "type": .string("string"),
                            "description": .string("Mode 2: Calendar name to delete events from (use with before_date/after_date)")
                        ]),
                        "calendar_source": .object([
                            "type": .string("string"),
                            "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")
                        ]),
                        "before_date": .object([
                            "type": .string("string"),
                            "description": .string("Mode 2: Delete events before this date (supports flexible formats)")
                        ]),
                        "after_date": .object([
                            "type": .string("string"),
                            "description": .string("Mode 2: Delete events after this date (supports flexible formats)")
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("Preview deletion without actually deleting (default: true). Set to false to execute deletion.")
                        ]),
                        "span": .object([
                            "type": .string("string"),
                            "enum": .array([.string("this"), .string("future"), .string("all")]),
                            "description": .string("For recurring events: 'this' (default) deletes only this occurrence, 'future' deletes this and all future occurrences, 'all' deletes the entire recurring series")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Feature 9: Find Duplicate Events
            Tool(
                name: "find_duplicate_events",
                description: "Find duplicate events across calendars. Useful before merging calendars to avoid duplicates. Matches by title (case-insensitive) and time (with configurable tolerance).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "calendar_names": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Calendar names to check for duplicates. If empty or omitted, checks ALL calendars.")
                        ]),
                        "start_date": .object([
                            "type": .string("string"),
                            "description": .string("Start date in ISO8601 format with timezone (e.g., 2026-01-01T00:00:00+08:00)")
                        ]),
                        "end_date": .object([
                            "type": .string("string"),
                            "description": .string("End date in ISO8601 format with timezone (e.g., 2026-12-31T23:59:59+08:00)")
                        ]),
                        "tolerance_minutes": .object([
                            "type": .string("integer"),
                            "description": .string("Time tolerance in minutes for matching (default: 5). Events within this time difference are considered duplicates.")
                        ])
                    ]),
                    "required": .array([.string("start_date"), .string("end_date")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),

            // Reminder Batch Operations
            Tool(
                name: "create_reminders_batch",
                description: "PREFERRED: Create multiple reminders in a single call. Use this instead of calling create_reminder multiple times - it's faster and more reliable. Returns detailed results for each reminder.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminders": .object([
                            "type": .string("array"),
                            "description": .string("Array of reminder objects to create"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "title": .object(["type": .string("string")]),
                                    "notes": .object(["type": .string("string")]),
                                    "due_date": .object(["type": .string("string"), "description": .string("Due date in ISO8601 format with timezone")]),
                                    "priority": .object(["type": .string("integer"), "description": .string("Priority: 0=none, 1=high, 5=medium, 9=low")]),
                                    "calendar_name": .object(["type": .string("string"), "description": .string("Target reminder list name (required)")]),
                                    "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google')")]),
                                    "tags": .object([
                                        "type": .string("array"),
                                        "items": .object(["type": .string("string")]),
                                        "description": .string("Tags (stored as #hashtags)")
                                    ])
                                ]),
                                "required": .array([.string("title"), .string("calendar_name")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("reminders")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "delete_reminders_batch",
                description: "PREFERRED: Delete multiple reminders in a single call. Use this instead of calling delete_reminder multiple times - it's faster and more reliable. Returns detailed success/failure counts.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminder_ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Array of reminder identifiers to delete")
                        ])
                    ]),
                    "required": .array([.string("reminder_ids")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Tag Tools
            Tool(
                name: "list_reminder_tags",
                description: "List all unique tags used across reminders. Tags are #hashtag text stored in reminder notes (MCP-level, not native Reminders.app tags). Returns tag names and usage counts.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional: only scan tags from this reminder list")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google')")]),
                        "include_completed": .object(["type": .string("boolean"), "description": .string("Include completed reminders (default: false, only scans incomplete)")])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
        ]
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        // List Tools handler
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        // Call Tool handler
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text("Server unavailable")], isError: true)
            }
            return await self.handleToolCall(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    // MARK: - Tool Call Handler

    private func handleToolCall(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let result = try await executeToolCall(name: name, arguments: arguments)
            let content = UntrustedContentWrapper.readTools.contains(name)
                ? UntrustedContentWrapper.wrap(result)
                : result
            return CallTool.Result(content: [.text(content)])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
        switch name {
        // Calendar Tools
        case "list_calendars":
            return try await handleListCalendars(arguments: arguments)
        case "create_calendar":
            return try await handleCreateCalendar(arguments: arguments)
        case "delete_calendar":
            return try await handleDeleteCalendar(arguments: arguments)
        case "update_calendar":
            return try await handleUpdateCalendar(arguments: arguments)

        // Event Tools
        case "list_events":
            return try await handleListEvents(arguments: arguments)
        case "create_event":
            return try await handleCreateEvent(arguments: arguments)
        case "update_event":
            return try await handleUpdateEvent(arguments: arguments)
        case "delete_event":
            return try await handleDeleteEvent(arguments: arguments)

        // Undo/Redo Tools
        case "undo":
            return try await handleUndo()
        case "redo":
            return try await handleRedo()
        case "undo_history":
            return try await handleUndoHistory(arguments: arguments)

        // Reminder Tools
        case "list_reminders":
            return try await handleListReminders(arguments: arguments)
        case "create_reminder":
            return try await handleCreateReminder(arguments: arguments)
        case "update_reminder":
            return try await handleUpdateReminder(arguments: arguments)
        case "complete_reminder":
            return try await handleCompleteReminder(arguments: arguments)
        case "delete_reminder":
            return try await handleDeleteReminder(arguments: arguments)
        case "search_reminders":
            return try await handleSearchReminders(arguments: arguments)

        // New Feature Tools
        case "search_events":
            return try await handleSearchEvents(arguments: arguments)
        case "list_events_quick":
            return try await handleListEventsQuick(arguments: arguments)
        case "create_events_batch":
            return try await handleCreateEventsBatch(arguments: arguments)
        case "check_conflicts":
            return try await handleCheckConflicts(arguments: arguments)
        case "copy_event":
            return try await handleCopyEvent(arguments: arguments)
        case "move_events_batch":
            return try await handleMoveEventsBatch(arguments: arguments)
        case "delete_events_batch":
            return try await handleDeleteEventsBatch(arguments: arguments)
        case "find_duplicate_events":
            return try await handleFindDuplicateEvents(arguments: arguments)
        case "create_reminders_batch":
            return try await handleCreateRemindersBatch(arguments: arguments)
        case "delete_reminders_batch":
            return try await handleDeleteRemindersBatch(arguments: arguments)
        case "list_reminder_tags":
            return try await handleListReminderTags(arguments: arguments)

        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Calendar Handlers

    private func handleListCalendars(arguments: [String: Value]) async throws -> String {
        var entityType: EKEntityType?
        if let typeStr = arguments["type"]?.stringValue {
            entityType = typeStr == "event" ? .event : typeStr == "reminder" ? .reminder : nil
        }

        let calendars = try await eventKitManager.listCalendars(for: entityType)
        let result = calendars.map { calendar -> [String: Any] in
            [
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": calendar.type.rawValue,
                "allowsContentModifications": calendar.allowsContentModifications,
                "isSubscribed": calendar.isSubscribed,
                "source": calendar.source.title,
                "source_type": sourceTypeString(calendar.source.sourceType)
            ]
        }
        return try formatJSON(result)
    }

    private func handleCreateCalendar(arguments: [String: Value]) async throws -> String {
        guard let title = arguments["title"]?.stringValue else {
            throw ToolError.invalidParameter("title is required")
        }
        guard let typeStr = arguments["type"]?.stringValue else {
            throw ToolError.invalidParameter("type is required")
        }

        let entityType: EKEntityType = typeStr == "reminder" ? .reminder : .event
        let color = arguments["color"]?.stringValue

        let result = try await eventKitManager.createCalendar(
            title: title,
            entityType: entityType,
            color: color
        )

        if result.isDuplicate {
            return try actionResult(["action": "skipped", "reason": "duplicate", "calendar": result.calendar.title, "id": result.calendar.calendarIdentifier])
        }
        return try actionResult(["action": "created", "calendar": result.calendar.title, "id": result.calendar.calendarIdentifier])
    }

    private func handleDeleteCalendar(arguments: [String: Value]) async throws -> String {
        guard let id = arguments["id"]?.stringValue else {
            throw ToolError.invalidParameter("id is required")
        }
        try await eventKitManager.deleteCalendar(identifier: id)
        return try actionResult(["action": "deleted", "id": id])
    }

    // MARK: - Event Handlers

    private func handleListEvents(arguments: [String: Value]) async throws -> String {
        guard let startStr = arguments["start_date"]?.stringValue else {
            throw ToolError.invalidParameter("start_date is required")
        }
        let startDate = try parseFlexibleDate(startStr)
        guard let endStr = arguments["end_date"]?.stringValue else {
            throw ToolError.invalidParameter("end_date is required")
        }
        let endDate = try parseFlexibleDate(endStr)

        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let filterMode = arguments["filter"]?.stringValue ?? "all"
        let sortMode = arguments["sort"]?.stringValue ?? "asc"
        let limit = arguments["limit"]?.intValue

        var events = try await eventKitManager.listEvents(
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        let totalInRange = events.count
        let now = Date()

        // Apply filter
        switch filterMode {
        case "past":
            events = events.filter { $0.endDate < now }
        case "future":
            events = events.filter { $0.startDate > now }
        case "all_day":
            events = events.filter { $0.isAllDay }
        default:
            break
        }

        let totalAfterFilter = events.count

        // Apply sort
        if sortMode == "desc" {
            events.sort { $0.startDate > $1.startDate }
        } else {
            events.sort { $0.startDate < $1.startDate }
        }

        // Apply limit
        if let limit = limit, limit > 0 && events.count > limit {
            events = Array(events.prefix(limit))
        }

        let result = events.map { formatEventDict($0) }

        var metadata: [String: Any] = [
            "total_in_range": totalInRange,
            "total_after_filter": totalAfterFilter,
            "returned": result.count,
            "filter": filterMode,
            "sort": sortMode
        ]
        if let limit = limit { metadata["limit"] = limit }

        let response: [String: Any] = [
            "events": result,
            "metadata": metadata
        ]
        return try formatJSON(response)
    }

    private func handleCreateEvent(arguments: [String: Value]) async throws -> String {
        guard let title = arguments["title"]?.stringValue else {
            throw ToolError.invalidParameter("title is required")
        }
        // Parse timezone first — naive datetimes (no offset) use this as default
        let timezone = try parseTimezone(from: arguments)

        guard let startStr = arguments["start_time"]?.stringValue else {
            throw ToolError.invalidParameter("start_time is required")
        }
        let startDate = try parseFlexibleDate(startStr, defaultTimezone: timezone)
        guard let endStr = arguments["end_time"]?.stringValue else {
            throw ToolError.invalidParameter("end_time is required")
        }
        let endDate = try parseFlexibleDate(endStr, defaultTimezone: timezone)

        let notes = arguments["notes"]?.stringValue
        let location = arguments["location"]?.stringValue
        let url = arguments["url"]?.stringValue
        try InputValidation.validateEventTextInput(title: title, notes: notes, location: location, url: url)

        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let isAllDay = arguments["all_day"]?.boolValue ?? false

        var alarmOffsets: [Int]?
        if let alarmsArray = arguments["alarms_minutes_offsets"]?.arrayValue {
            alarmOffsets = try alarmsArray.enumerated().map { idx, v in
                guard let n = v.intValue else {
                    throw ToolError.invalidParameter("alarms_minutes_offsets[\(idx)] must be an integer")
                }
                return n
            }
        }

        let recurrenceRule = try parseRecurrenceRule(from: arguments, defaultTimezone: timezone)
        let structuredLocation = parseStructuredLocation(from: arguments)

        let result = try await eventKitManager.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: notes,
            location: location,
            url: url,
            calendarName: calendarName,
            calendarSource: calendarSource,
            isAllDay: isAllDay,
            alarmOffsets: alarmOffsets,
            recurrenceRule: recurrenceRule,
            structuredLocation: structuredLocation,
            timezone: timezone
        )

        if result.isDuplicate {
            return try actionResult(["action": "skipped", "reason": "duplicate", "title": result.event.title ?? title, "id": result.event.eventIdentifier ?? "unknown"])
        }
        return try actionResult(["action": "created", "title": result.event.title ?? title, "id": result.event.eventIdentifier ?? "unknown"])
    }

    private func handleUpdateEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }

        // Parse timezone first — naive datetimes (no offset) use this as default
        let timezone = try parseTimezone(from: arguments)

        let title = arguments["title"]?.stringValue
        let startDate: Date? = try arguments["start_time"]?.stringValue.map { try parseFlexibleDate($0, defaultTimezone: timezone) }
        let endDate: Date? = try arguments["end_time"]?.stringValue.map { try parseFlexibleDate($0, defaultTimezone: timezone) }
        let notes = arguments["notes"]?.stringValue
        let location = arguments["location"]?.stringValue
        let url = arguments["url"]?.stringValue
        try InputValidation.validateEventTextInput(title: title, notes: notes, location: location, url: url)

        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let isAllDay = arguments["all_day"]?.boolValue
        let occurrenceDate: Date? = try arguments["occurrence_date"]?.stringValue.map { try parseFlexibleDate($0, defaultTimezone: timezone) }

        let spanStr = arguments["span"]?.stringValue ?? "this"
        let span: EKSpan
        switch spanStr {
        case "future": span = .futureEvents
        case "all": span = .futureEvents  // "all" on update = modify entire series from master
        default: span = .thisEvent
        }

        var alarmOffsets: [Int]?
        if let alarmsArray = arguments["alarms_minutes_offsets"]?.arrayValue {
            alarmOffsets = try alarmsArray.enumerated().map { idx, v in
                guard let n = v.intValue else {
                    throw ToolError.invalidParameter("alarms_minutes_offsets[\(idx)] must be an integer")
                }
                return n
            }
        }

        let recurrenceRule = try parseRecurrenceRule(from: arguments, defaultTimezone: timezone)
        let clearRecurrence = arguments["clear_recurrence"]?.boolValue ?? false
        let structuredLocation = parseStructuredLocation(from: arguments)
        let clearTimezone = arguments["clear_timezone"]?.boolValue ?? false
        if clearTimezone && timezone != nil {
            throw ToolError.invalidParameter("Cannot specify both timezone and clear_timezone")
        }

        let event = try await eventKitManager.updateEvent(
            identifier: eventId,
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: notes,
            location: location,
            url: url,
            calendarName: calendarName,
            calendarSource: calendarSource,
            isAllDay: isAllDay,
            alarmOffsets: alarmOffsets,
            recurrenceRule: recurrenceRule,
            clearRecurrence: clearRecurrence,
            structuredLocation: structuredLocation,
            span: span,
            occurrenceDate: occurrenceDate,
            applyToAll: spanStr == "all",
            timezone: timezone,
            clearTimezone: clearTimezone
        )

        return try actionResult(["action": "updated", "title": event.title ?? "", "id": eventId])
    }

    private func handleDeleteEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }

        // Use the event's own timezone for occurrence_date parsing to match findOccurrence's day boundary
        let eventTz = await eventKitManager.getEventTimezone(identifier: eventId)
        let spanStr = arguments["span"]?.stringValue ?? "this"
        let occurrenceDate: Date? = try arguments["occurrence_date"]?.stringValue.map { try parseFlexibleDate($0, defaultTimezone: eventTz) }

        if spanStr == "all" {
            try await eventKitManager.deleteEventSeries(identifier: eventId)
            return try actionResult(["action": "deleted", "id": eventId, "span": "all"])
        }

        let span: EKSpan = spanStr == "future" ? .futureEvents : .thisEvent
        try await eventKitManager.deleteEvent(identifier: eventId, span: span, occurrenceDate: occurrenceDate)
        return try actionResult(["action": "deleted", "id": eventId, "span": spanStr])
    }

    // MARK: - Undo/Redo Handlers

    private func handleUndo() async throws -> String {
        guard let record = await CalendarUndoManager.shared.popUndo() else {
            return try actionResult(["action": "undo", "success": false, "message": "Nothing to undo"])
        }
        let message = try await eventKitManager.executeUndo(record.operation)
        return try actionResult(["action": "undo", "success": true, "message": message])
    }

    private func handleRedo() async throws -> String {
        guard let record = await CalendarUndoManager.shared.popRedo() else {
            return try actionResult(["action": "redo", "success": false, "message": "Nothing to redo"])
        }
        let message = try await eventKitManager.executeRedo(record.operation)
        return try actionResult(["action": "redo", "success": true, "message": message])
    }

    private func handleUndoHistory(arguments: [String: Value]) async throws -> String {
        let limit = arguments["limit"]?.intValue ?? 10
        let history = await CalendarUndoManager.shared.history()
        let undoCount = await CalendarUndoManager.shared.undoCount
        let redoCount = await CalendarUndoManager.shared.redoCount

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let entries = history.prefix(limit).map { entry -> [String: Any] in
            [
                "index": entry.index,
                "description": entry.description,
                "time": dateFormatter.string(from: entry.timestamp)
            ]
        }

        let response: [String: Any] = [
            "undo_available": undoCount,
            "redo_available": redoCount,
            "history": entries
        ]
        return try formatJSON(response)
    }

    // MARK: - Reminder Handlers

    private func handleListReminders(arguments: [String: Value]) async throws -> String {
        let filterMode = arguments["filter"]?.stringValue
        let sortMode = arguments["sort"]?.stringValue ?? "due_date"
        let limit = arguments["limit"]?.intValue
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        // Determine completion filter: 'filter' parameter takes priority over legacy 'completed'
        let completed: Bool?
        if let filterMode = filterMode {
            switch filterMode {
            case "completed": completed = true
            case "incomplete", "overdue": completed = false
            default: completed = nil  // "all"
            }
        } else {
            completed = arguments["completed"]?.boolValue
        }

        var reminders = try await eventKitManager.listReminders(
            completed: completed,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        let totalFetched = reminders.count
        let now = Date()

        // Apply overdue filter (incomplete + past due date)
        if filterMode == "overdue" {
            reminders = reminders.filter { reminder in
                !reminder.isCompleted &&
                safeDateFromComponents(reminder.dueDateComponents).map { $0 < now } == true
            }
        }

        let totalAfterFilter = reminders.count

        // Apply sort
        reminders.sort { r1, r2 in
            switch sortMode {
            case "priority":
                // Priority sort: 1(high) → 5(medium) → 9(low) → 0(none)
                let p1 = r1.priority == 0 ? Int.max : r1.priority
                let p2 = r2.priority == 0 ? Int.max : r2.priority
                return p1 < p2
            case "title":
                return (r1.title ?? "").localizedCaseInsensitiveCompare(r2.title ?? "") == .orderedAscending
            case "creation_date":
                let d1 = r1.creationDate ?? Date.distantPast
                let d2 = r2.creationDate ?? Date.distantPast
                return d1 < d2
            default: // "due_date"
                let d1 = safeDateFromComponents(r1.dueDateComponents)
                let d2 = safeDateFromComponents(r2.dueDateComponents)
                if d1 == nil && d2 == nil { return false }
                if d1 == nil { return false }  // nulls last
                if d2 == nil { return true }
                return d1! < d2!
            }
        }

        // Apply limit
        if let limit = limit, limit > 0 && reminders.count > limit {
            reminders = Array(reminders.prefix(limit))
        }

        let result = reminders.map { [self] reminder -> [String: Any] in
            let (cleanNotes, tags) = extractTags(from: reminder.notes)
            var dict: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "is_completed": reminder.isCompleted,
                "priority": reminder.priority,
                "calendar": reminder.calendar.title,
                "timezone": TimeZone.current.identifier
            ]
            if let notes = cleanNotes { dict["notes"] = notes }
            if !tags.isEmpty { dict["tags"] = tags }
            if let dueDate = safeDateFromComponents(reminder.dueDateComponents) {
                dict["due_date"] = dateFormatter.string(from: dueDate)
                dict["due_date_local"] = localDateFormatter.string(from: dueDate)
                dict["is_overdue"] = !reminder.isCompleted && dueDate < now
            }
            if let completionDate = reminder.completionDate {
                dict["completion_date"] = dateFormatter.string(from: completionDate)
                dict["completion_date_local"] = localDateFormatter.string(from: completionDate)
            }
            if let creationDate = reminder.creationDate {
                dict["creation_date"] = dateFormatter.string(from: creationDate)
                dict["creation_date_local"] = localDateFormatter.string(from: creationDate)
            }
            // Location trigger info (from location-based alarms)
            if let alarms = reminder.alarms {
                for alarm in alarms {
                    if let structured = alarm.structuredLocation {
                        var triggerDict: [String: Any] = ["title": structured.title ?? ""]
                        if let geo = structured.geoLocation {
                            triggerDict["latitude"] = geo.coordinate.latitude
                            triggerDict["longitude"] = geo.coordinate.longitude
                        }
                        if structured.radius > 0 { triggerDict["radius"] = structured.radius }
                        switch alarm.proximity {
                        case .enter: triggerDict["proximity"] = "enter"
                        case .leave: triggerDict["proximity"] = "leave"
                        default: break
                        }
                        dict["location_trigger"] = triggerDict
                        break  // Only show first location trigger
                    }
                }
            }
            return dict
        }

        var metadata: [String: Any] = [
            "total_fetched": totalFetched,
            "total_after_filter": totalAfterFilter,
            "returned": result.count,
            "filter": filterMode ?? "all",
            "sort": sortMode
        ]
        if let limit = limit { metadata["limit"] = limit }

        let response: [String: Any] = [
            "reminders": result,
            "metadata": metadata
        ]
        return try formatJSON(response)
    }

    private func handleCreateReminder(arguments: [String: Value]) async throws -> String {
        guard let title = arguments["title"]?.stringValue else {
            throw ToolError.invalidParameter("title is required")
        }

        let userNotes = arguments["notes"]?.stringValue
        try InputValidation.validateReminderTextInput(title: title, notes: userNotes)

        let tags = arguments["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let notes = buildNotesWithTags(notes: userNotes, tags: tags)

        let dueDate: Date? = try arguments["due_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let priority = arguments["priority"]?.intValue ?? 0
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let recurrenceRule = try parseRecurrenceRule(from: arguments)
        let locationTrigger = try parseLocationTrigger(from: arguments)

        let result = try await eventKitManager.createReminder(
            title: title,
            notes: notes,
            dueDate: dueDate,
            priority: priority,
            calendarName: calendarName,
            calendarSource: calendarSource,
            recurrenceRule: recurrenceRule,
            locationTrigger: locationTrigger
        )

        if result.isDuplicate {
            return try actionResult(["action": "skipped", "reason": "duplicate", "title": result.reminder.title ?? title, "id": result.reminder.calendarItemIdentifier])
        }
        var fields: [String: Any] = ["action": "created", "title": result.reminder.title ?? title, "id": result.reminder.calendarItemIdentifier]
        if !tags.isEmpty {
            fields["tags"] = tags
        }
        return try actionResult(fields)
    }

    private func handleUpdateReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }

        let title = arguments["title"]?.stringValue
        let userNotes = arguments["notes"]?.stringValue
        try InputValidation.validateReminderTextInput(title: title, notes: userNotes)

        let newTags = arguments["tags"]?.arrayValue?.compactMap { $0.stringValue }
        let clearTags = arguments["clear_tags"]?.boolValue ?? false
        let dueDate: Date? = try arguments["due_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let clearDueDate = arguments["clear_due_date"]?.boolValue ?? false
        if clearDueDate && dueDate != nil {
            throw ToolError.invalidParameter("Cannot specify both due_date and clear_due_date")
        }
        let priority = arguments["priority"]?.intValue
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let locationTrigger = try parseLocationTrigger(from: arguments)
        let clearLocationTrigger = arguments["clear_location_trigger"]?.boolValue ?? false

        // Determine final notes:
        // If user provides notes, use their notes as the base (replacing existing notes content)
        // If user provides tags or clear_tags, merge tags with existing or new notes
        var finalNotes: String? = nil
        let hasNotesChange = userNotes != nil
        let hasTagChange = newTags != nil || clearTags

        if hasNotesChange || hasTagChange {
            // Need to read existing reminder to get current notes for tag merging
            let existingReminder = try await eventKitManager.getReminder(identifier: reminderId)
            let baseNotes: String?
            if hasNotesChange {
                // User is replacing notes content; use their new notes as base
                baseNotes = userNotes
            } else {
                // Keep existing notes content (without old tags)
                let (cleanExisting, _) = extractTags(from: existingReminder.notes)
                baseNotes = cleanExisting
            }

            if clearTags {
                finalNotes = baseNotes
            } else if let tags = newTags {
                finalNotes = buildNotesWithTags(notes: baseNotes, tags: tags)
            } else if hasNotesChange {
                // User changed notes but not tags — preserve existing tags
                let (_, existingTags) = extractTags(from: existingReminder.notes)
                finalNotes = buildNotesWithTags(notes: baseNotes, tags: existingTags)
            }
        }

        let reminder = try await eventKitManager.updateReminder(
            identifier: reminderId,
            title: title,
            notes: finalNotes,
            dueDate: dueDate,
            priority: priority,
            calendarName: calendarName,
            calendarSource: calendarSource,
            locationTrigger: locationTrigger,
            clearLocationTrigger: clearLocationTrigger,
            clearDueDate: clearDueDate
        )

        return try actionResult(["action": "updated", "title": reminder.title ?? "", "id": reminderId])
    }

    private func handleCompleteReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }

        let completed = arguments["completed"]?.boolValue ?? true

        let reminder = try await eventKitManager.completeReminder(
            identifier: reminderId,
            completed: completed
        )

        return try actionResult(["action": "completed", "title": reminder.title ?? "", "id": reminderId, "is_completed": reminder.isCompleted])
    }

    private func handleDeleteReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }

        try await eventKitManager.deleteReminder(identifier: reminderId)
        return try actionResult(["action": "deleted", "id": reminderId])
    }

    private func handleUpdateCalendar(arguments: [String: Value]) async throws -> String {
        guard let id = arguments["id"]?.stringValue else {
            throw ToolError.invalidParameter("id is required")
        }

        let title = arguments["title"]?.stringValue
        let color = arguments["color"]?.stringValue

        if title == nil && color == nil {
            throw ToolError.invalidParameter("At least one of 'title' or 'color' must be provided")
        }

        let calendar = try await eventKitManager.updateCalendar(
            identifier: id,
            title: title,
            color: color
        )

        return try actionResult(["action": "updated", "calendar": calendar.title, "id": calendar.calendarIdentifier])
    }

    private func handleSearchReminders(arguments: [String: Value]) async throws -> String {
        var keywords: [String] = []

        if let keywordsArray = arguments["keywords"]?.arrayValue {
            keywords = keywordsArray.compactMap { $0.stringValue }
        } else if let keyword = arguments["keyword"]?.stringValue {
            keywords = [keyword]
        }

        let tagFilter = arguments["tag"]?.stringValue

        if keywords.isEmpty && tagFilter == nil {
            throw ToolError.invalidParameter("Either 'keyword', 'keywords', or 'tag' is required")
        }

        let matchMode = arguments["match_mode"]?.stringValue ?? "any"
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let completed = arguments["completed"]?.boolValue

        // If only tag filter (no keywords), pass empty to get all reminders, then filter by tag
        var reminders = try await eventKitManager.searchReminders(
            keywords: keywords,
            matchMode: matchMode,
            calendarName: calendarName,
            calendarSource: calendarSource,
            completed: completed
        )

        // Apply tag filter
        if let tagFilter = tagFilter {
            let normalizedTag = tagFilter.hasPrefix("#") ? String(tagFilter.dropFirst()) : tagFilter
            reminders = reminders.filter { reminder in
                let (_, tags) = extractTags(from: reminder.notes)
                return tags.contains(where: { $0.caseInsensitiveCompare(normalizedTag) == .orderedSame })
            }
        }

        let result = reminders.map { [self] reminder -> [String: Any] in
            let (cleanNotes, tags) = extractTags(from: reminder.notes)
            var dict: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "is_completed": reminder.isCompleted,
                "priority": reminder.priority,
                "calendar": reminder.calendar.title,
                "timezone": TimeZone.current.identifier
            ]
            if let notes = cleanNotes { dict["notes"] = notes }
            if !tags.isEmpty { dict["tags"] = tags }
            if let dueDate = safeDateFromComponents(reminder.dueDateComponents) {
                dict["due_date"] = dateFormatter.string(from: dueDate)
                dict["due_date_local"] = localDateFormatter.string(from: dueDate)
            }
            if let completionDate = reminder.completionDate {
                dict["completion_date"] = dateFormatter.string(from: completionDate)
                dict["completion_date_local"] = localDateFormatter.string(from: completionDate)
            }
            // Location trigger info
            if let alarms = reminder.alarms {
                for alarm in alarms {
                    if let structured = alarm.structuredLocation {
                        var triggerDict: [String: Any] = ["title": structured.title ?? ""]
                        if let geo = structured.geoLocation {
                            triggerDict["latitude"] = geo.coordinate.latitude
                            triggerDict["longitude"] = geo.coordinate.longitude
                        }
                        if structured.radius > 0 { triggerDict["radius"] = structured.radius }
                        switch alarm.proximity {
                        case .enter: triggerDict["proximity"] = "enter"
                        case .leave: triggerDict["proximity"] = "leave"
                        default: break
                        }
                        dict["location_trigger"] = triggerDict
                        break
                    }
                }
            }
            return dict
        }

        var response: [String: Any] = [
            "match_mode": matchMode,
            "result_count": reminders.count,
            "reminders": result
        ]
        if !keywords.isEmpty { response["keywords"] = keywords }
        if let tagFilter = tagFilter { response["tag_filter"] = tagFilter }
        return try formatJSON(response)
    }

    private func handleCreateRemindersBatch(arguments: [String: Value]) async throws -> String {
        guard let remindersArray = arguments["reminders"]?.arrayValue else {
            throw ToolError.invalidParameter("reminders array is required")
        }

        var results: [[String: Any]] = []

        for (index, reminderValue) in remindersArray.enumerated() {
            guard let reminderDict = reminderValue.objectValue else {
                results.append(["index": index, "success": false, "error": "Invalid reminder format"])
                continue
            }

            guard let title = reminderDict["title"]?.stringValue else {
                results.append(["index": index, "success": false, "error": "title is required"])
                continue
            }

            do {
                let batchUserNotes = reminderDict["notes"]?.stringValue
                try InputValidation.validateReminderTextInput(title: title, notes: batchUserNotes)

                let batchDueDate: Date? = try reminderDict["due_date"]?.stringValue.map { try parseFlexibleDate($0) }
                let batchTags = reminderDict["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let batchNotes = buildNotesWithTags(notes: batchUserNotes, tags: batchTags)
                let result = try await eventKitManager.createReminder(
                    title: title,
                    notes: batchNotes,
                    dueDate: batchDueDate,
                    priority: reminderDict["priority"]?.intValue ?? 0,
                    calendarName: reminderDict["calendar_name"]?.stringValue,
                    calendarSource: reminderDict["calendar_source"]?.stringValue
                )
                var entry: [String: Any] = [
                    "index": index,
                    "success": true,
                    "reminder_id": result.reminder.calendarItemIdentifier,
                    "title": result.reminder.title ?? title
                ]
                if result.isDuplicate {
                    entry["skipped"] = true
                }
                results.append(entry)
            } catch {
                results.append([
                    "index": index,
                    "success": false,
                    "error": error.localizedDescription
                ])
            }
        }

        let successCount = results.filter { ($0["success"] as? Bool) == true && ($0["skipped"] as? Bool) != true }.count
        let skippedCount = results.filter { ($0["skipped"] as? Bool) == true }.count
        let failedCount = remindersArray.count - successCount - skippedCount
        var response: [String: Any] = [
            "total": remindersArray.count,
            "succeeded": successCount,
            "failed": failedCount,
            "results": results
        ]
        if skippedCount > 0 {
            response["skipped"] = skippedCount
        }
        return try formatJSON(response)
    }

    private func handleDeleteRemindersBatch(arguments: [String: Value]) async throws -> String {
        guard let reminderIdsArray = arguments["reminder_ids"]?.arrayValue else {
            throw ToolError.invalidParameter("reminder_ids array is required")
        }

        let reminderIds = reminderIdsArray.compactMap { $0.stringValue }
        if reminderIds.isEmpty {
            throw ToolError.invalidParameter("reminder_ids must contain at least one reminder ID")
        }

        let result = try await eventKitManager.deleteRemindersBatch(identifiers: reminderIds)

        var response: [String: Any] = [
            "total": reminderIds.count,
            "succeeded": result.successCount,
            "failed": result.failedCount
        ]

        if !result.failures.isEmpty {
            response["failures"] = result.failures.map { failure -> [String: String] in
                ["reminder_id": failure.identifier, "error": failure.error]
            }
        }

        return try formatJSON(response)
    }

    // MARK: - Tag Handlers

    private func handleListReminderTags(arguments: [String: Value]) async throws -> String {
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let includeCompleted = arguments["include_completed"]?.boolValue ?? false

        let completed: Bool? = includeCompleted ? nil : false

        let reminders = try await eventKitManager.listReminders(
            completed: completed,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        // Collect all tags with counts
        var tagCounts: [String: Int] = [:]
        for reminder in reminders {
            let (_, tags) = extractTags(from: reminder.notes)
            for tag in tags {
                tagCounts[tag, default: 0] += 1
            }
        }

        // Sort by count (descending), then alphabetically
        let sortedTags = tagCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        let tagList = sortedTags.map { ["tag": $0.key, "count": $0.value] as [String: Any] }

        let response: [String: Any] = [
            "total_tags": tagCounts.count,
            "total_reminders_scanned": reminders.count,
            "include_completed": includeCompleted,
            "tags": tagList
        ]
        return try formatJSON(response)
    }

    // MARK: - New Feature Handlers

    /// Feature 2: Search events by keyword(s)
    private func handleSearchEvents(arguments: [String: Value]) async throws -> String {
        // Support both single keyword and multiple keywords
        var keywords: [String] = []

        if let keywordsArray = arguments["keywords"]?.arrayValue {
            keywords = keywordsArray.compactMap { $0.stringValue }
        } else if let keyword = arguments["keyword"]?.stringValue {
            keywords = [keyword]
        }

        if keywords.isEmpty {
            throw ToolError.invalidParameter("Either 'keyword' or 'keywords' is required")
        }

        let matchMode = arguments["match_mode"]?.stringValue ?? "any"
        let userStartDate: Date? = try arguments["start_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let userEndDate: Date? = try arguments["end_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        // Compute effective search range (same defaults as EventKitManager)
        let now = Date()
        let effectiveStart = userStartDate ?? Calendar.current.date(byAdding: .year, value: -2, to: now)!
        let effectiveEnd = userEndDate ?? Calendar.current.date(byAdding: .year, value: 2, to: now)!

        let events = try await eventKitManager.searchEvents(
            keywords: keywords,
            matchMode: matchMode,
            startDate: effectiveStart,
            endDate: effectiveEnd,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        let result = events.map { formatEventDict($0) }

        let response: [String: Any] = [
            "keywords": keywords,
            "match_mode": matchMode,
            "result_count": events.count,
            "searched_range": [
                "start": dateFormatter.string(from: effectiveStart),
                "start_local": localDateFormatter.string(from: effectiveStart),
                "end": dateFormatter.string(from: effectiveEnd),
                "end_local": localDateFormatter.string(from: effectiveEnd),
                "is_default_range": userStartDate == nil || userEndDate == nil
            ] as [String: Any],
            "events": result
        ]
        return try formatJSON(response)
    }

    /// Feature 3: List events with quick time range
    private func handleListEventsQuick(arguments: [String: Value]) async throws -> String {
        guard let range = arguments["range"]?.stringValue else {
            throw ToolError.invalidParameter("range is required")
        }

        let weekStartsOn = arguments["week_starts_on"]?.stringValue ?? "system"
        let (startDate, endDate, effectiveWeekStart) = getDateRange(for: range, weekStartsOn: weekStartsOn)
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let events = try await eventKitManager.listEvents(
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        let result = events.map { formatEventDict($0) }

        // Include the computed date range in response
        var response: [String: Any] = [
            "range": range,
            "start_date": dateFormatter.string(from: startDate),
            "start_date_local": localDateFormatter.string(from: startDate),
            "end_date": dateFormatter.string(from: endDate),
            "end_date_local": localDateFormatter.string(from: endDate),
            "timezone": TimeZone.current.identifier,
            "events": result
        ]
        // Include week_starts_on info for this_week/next_week ranges
        if range == "this_week" || range == "next_week" {
            response["week_starts_on"] = effectiveWeekStart
        }
        return try formatJSON(response)
    }

    /// Feature 4: Create multiple events at once
    private func handleCreateEventsBatch(arguments: [String: Value]) async throws -> String {
        guard let eventsArray = arguments["events"]?.arrayValue else {
            throw ToolError.invalidParameter("events array is required")
        }

        var results: [[String: Any]] = []

        for (index, eventValue) in eventsArray.enumerated() {
            guard let eventDict = eventValue.objectValue else {
                results.append(["index": index, "success": false, "error": "Invalid event format"])
                continue
            }

            guard let title = eventDict["title"]?.stringValue else {
                results.append(["index": index, "success": false, "error": "title is required"])
                continue
            }
            // Parse timezone first so naive datetimes use event timezone
            let batchTimezone: TimeZone?
            do {
                batchTimezone = try parseTimezone(from: eventDict)
            } catch {
                results.append(["index": index, "success": false, "error": error.localizedDescription])
                continue
            }

            guard let startStr = eventDict["start_time"]?.stringValue else {
                results.append(["index": index, "success": false, "error": "start_time is required"])
                continue
            }
            let startDate: Date
            do {
                startDate = try parseFlexibleDate(startStr, defaultTimezone: batchTimezone)
            } catch {
                results.append(["index": index, "success": false, "error": error.localizedDescription])
                continue
            }
            guard let endStr = eventDict["end_time"]?.stringValue else {
                results.append(["index": index, "success": false, "error": "end_time is required"])
                continue
            }
            let endDate: Date
            do {
                endDate = try parseFlexibleDate(endStr, defaultTimezone: batchTimezone)
            } catch {
                results.append(["index": index, "success": false, "error": error.localizedDescription])
                continue
            }

            do {
                // Parse recurrence and structured location from batch item
                let batchRecurrence = try parseRecurrenceRule(from: eventDict, defaultTimezone: batchTimezone)
                let batchStructuredLocation = parseStructuredLocation(from: eventDict)

                let batchNotes = eventDict["notes"]?.stringValue
                let batchLocation = eventDict["location"]?.stringValue
                try InputValidation.validateEventTextInput(title: title, notes: batchNotes, location: batchLocation, url: nil)

                let result = try await eventKitManager.createEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    notes: batchNotes,
                    location: batchLocation,
                    url: nil,
                    calendarName: eventDict["calendar_name"]?.stringValue,
                    calendarSource: eventDict["calendar_source"]?.stringValue,
                    isAllDay: eventDict["all_day"]?.boolValue ?? false,
                    alarmOffsets: nil,
                    recurrenceRule: batchRecurrence,
                    structuredLocation: batchStructuredLocation,
                    timezone: batchTimezone
                )
                var entry: [String: Any] = [
                    "index": index,
                    "success": true,
                    "event_id": result.event.eventIdentifier ?? "",
                    "title": result.event.title ?? title
                ]
                if result.isDuplicate {
                    entry["skipped"] = true
                }
                results.append(entry)
            } catch {
                results.append([
                    "index": index,
                    "success": false,
                    "error": error.localizedDescription
                ])
            }
        }

        let successCount = results.filter { ($0["success"] as? Bool) == true && ($0["skipped"] as? Bool) != true }.count
        let skippedCount = results.filter { ($0["skipped"] as? Bool) == true }.count
        let failedCount = eventsArray.count - successCount - skippedCount
        var response: [String: Any] = [
            "total": eventsArray.count,
            "succeeded": successCount,
            "failed": failedCount,
            "results": results
        ]
        if skippedCount > 0 {
            response["skipped"] = skippedCount
        }

        // Collect unique titles from the batch to find similar existing events.
        // Failures here are advisory-only — they don't affect batch success —
        // but must be visible so callers know the hint is incomplete rather
        // than treating an error as "no similar events exist".
        let batchTitles = Set(eventsArray.compactMap { $0.objectValue?["title"]?.stringValue })
        var similarHints: [[String: Any]] = []
        var similarLookupErrors: [String: String] = [:]
        let createdIds = Set(results.compactMap { $0["event_id"] as? String })
        for title in batchTitles {
            do {
                let similar = try await eventKitManager.findSimilarEvents(title: title, limit: 3)
                for event in similar {
                    if let eid = event.eventIdentifier, createdIds.contains(eid) { continue }
                    similarHints.append([
                        "matched_title": title,
                        "existing_title": event.title ?? "",
                        "existing_calendar": event.calendar.title,
                        "existing_date": dateFormatter.string(from: event.startDate),
                        "existing_date_local": localDateFormatter.string(from: event.startDate)
                    ])
                }
            } catch {
                FileHandle.standardError.write(Data("findSimilarEvents(\(title)) failed: \(error.localizedDescription)\n".utf8))
                similarLookupErrors[title] = error.localizedDescription
            }
        }
        if !similarHints.isEmpty {
            response["similar_events"] = similarHints
        }
        if !similarLookupErrors.isEmpty {
            response["similar_events_errors"] = similarLookupErrors
        }

        return try formatJSON(response)
    }

    /// Feature 5: Check for conflicting events
    private func handleCheckConflicts(arguments: [String: Value]) async throws -> String {
        guard let startStr = arguments["start_time"]?.stringValue else {
            throw ToolError.invalidParameter("start_time is required")
        }
        let startDate = try parseFlexibleDate(startStr)
        guard let endStr = arguments["end_time"]?.stringValue else {
            throw ToolError.invalidParameter("end_time is required")
        }
        let endDate = try parseFlexibleDate(endStr)

        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let excludeEventId = arguments["exclude_event_id"]?.stringValue

        let conflicts = try await eventKitManager.checkConflicts(
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource,
            excludeEventId: excludeEventId
        )

        let result = conflicts.map { formatEventDict($0) }

        let response: [String: Any] = [
            "has_conflicts": !conflicts.isEmpty,
            "conflict_count": conflicts.count,
            "check_range": [
                "start": dateFormatter.string(from: startDate),
                "start_local": localDateFormatter.string(from: startDate),
                "end": dateFormatter.string(from: endDate),
                "end_local": localDateFormatter.string(from: endDate)
            ],
            "conflicts": result
        ]
        return try formatJSON(response)
    }

    /// Feature 6: Copy event to another calendar
    private func handleCopyEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }
        guard let targetCalendar = arguments["target_calendar"]?.stringValue else {
            throw ToolError.invalidParameter("target_calendar is required")
        }

        let targetCalendarSource = arguments["target_calendar_source"]?.stringValue
        let deleteOriginal = arguments["delete_original"]?.boolValue ?? false

        let newEvent = try await eventKitManager.copyEvent(
            identifier: eventId,
            toCalendarName: targetCalendar,
            toCalendarSource: targetCalendarSource,
            deleteOriginal: deleteOriginal
        )

        let action = deleteOriginal ? "moved" : "copied"
        return try actionResult(["action": action, "title": newEvent.title ?? "", "target_calendar": targetCalendar, "new_id": newEvent.eventIdentifier ?? "unknown"])
    }

    /// Feature 7: Move multiple events to another calendar
    private func handleMoveEventsBatch(arguments: [String: Value]) async throws -> String {
        guard let eventIds = arguments["event_ids"]?.arrayValue else {
            throw ToolError.invalidParameter("event_ids array is required")
        }
        guard let targetCalendar = arguments["target_calendar"]?.stringValue else {
            throw ToolError.invalidParameter("target_calendar is required")
        }

        let targetCalendarSource = arguments["target_calendar_source"]?.stringValue
        let ids = eventIds.compactMap { $0.stringValue }
        if ids.isEmpty {
            throw ToolError.invalidParameter("event_ids must contain at least one event ID")
        }

        var results: [[String: Any]] = []

        for eventId in ids {
            do {
                let event = try await eventKitManager.copyEvent(
                    identifier: eventId,
                    toCalendarName: targetCalendar,
                    toCalendarSource: targetCalendarSource,
                    deleteOriginal: true  // Move = copy + delete original
                )
                results.append([
                    "event_id": eventId,
                    "success": true,
                    "new_event_id": event.eventIdentifier ?? "",
                    "title": event.title ?? ""
                ])
            } catch {
                results.append([
                    "event_id": eventId,
                    "success": false,
                    "error": error.localizedDescription
                ])
            }
        }

        let successCount = results.filter { ($0["success"] as? Bool) == true }.count
        let response: [String: Any] = [
            "total": ids.count,
            "succeeded": successCount,
            "failed": ids.count - successCount,
            "target_calendar": targetCalendar,
            "results": results
        ]
        return try formatJSON(response)
    }

    /// Delete a list of events, handling span="all" by calling deleteEventSeries per event.
    /// items pairs each event ID with its occurrence date (for recurring event resolution).
    private func deleteEventsWithSpan(
        items: [(identifier: String, occurrenceDate: Date?)],
        spanStr: String,
        mode: String,
        extraFields: [String: Any] = [:]
    ) async throws -> String {
        let deleteAll = spanStr == "all"

        if deleteAll {
            // Deduplicate IDs for series deletion (each series only needs one delete)
            let uniqueIds = Array(Set(items.map(\.identifier)))
            var successCount = 0
            var failures: [[String: String]] = []
            for id in uniqueIds {
                do {
                    try await eventKitManager.deleteEventSeries(identifier: id)
                    successCount += 1
                } catch {
                    failures.append(["event_id": id, "error": error.localizedDescription])
                }
            }
            var response: [String: Any] = [
                "dry_run": false,
                "mode": mode,
                "total": uniqueIds.count,
                "succeeded": successCount,
                "failed": uniqueIds.count - successCount,
                "span": "all"
            ]
            for (k, v) in extraFields { response[k] = v }
            if !failures.isEmpty { response["failures"] = failures }
            return try formatJSON(response)
        }

        let span: EKSpan = spanStr == "future" ? .futureEvents : .thisEvent
        let result = try await eventKitManager.deleteEventsBatch(items: items, span: span)
        var response: [String: Any] = [
            "dry_run": false,
            "mode": mode,
            "total": items.count,
            "succeeded": result.successCount,
            "failed": result.failedCount,
            "span": spanStr
        ]
        for (k, v) in extraFields { response[k] = v }
        if !result.failures.isEmpty {
            response["failures"] = result.failures.map { ["event_id": $0.identifier, "error": $0.error] }
        }
        return try formatJSON(response)
    }

    /// Feature 8: Delete multiple events at once (by IDs or by date range)
    private func handleDeleteEventsBatch(arguments: [String: Value]) async throws -> String {
        let dryRun = arguments["dry_run"]?.boolValue ?? true
        let spanStr = arguments["span"]?.stringValue ?? "this"

        // Determine mode: by event_ids or by calendar + date range
        if let eventIdsArray = arguments["event_ids"]?.arrayValue {
            // Mode 1: Delete by event IDs
            let eventIds = eventIdsArray.compactMap { $0.stringValue }
            if eventIds.isEmpty {
                throw ToolError.invalidParameter("event_ids must contain at least one event ID")
            }

            if dryRun {
                // Preview mode: show what would be deleted
                var preview: [[String: Any]] = []
                for id in eventIds {
                    do {
                        let event = try await eventKitManager.getEvent(identifier: id)
                        preview.append([
                            "event_id": id,
                            "title": event.title ?? "",
                            "start_date_local": localDateFormatter.string(from: event.startDate),
                            "end_date_local": localDateFormatter.string(from: event.endDate),
                            "calendar": event.calendar.title
                        ])
                    } catch {
                        preview.append(["event_id": id, "error": error.localizedDescription])
                    }
                }
                let response: [String: Any] = [
                    "dry_run": true,
                    "mode": "by_event_ids",
                    "total": eventIds.count,
                    "events_to_delete": preview,
                    "message": "Set dry_run=false to execute deletion"
                ]
                return try formatJSON(response)
            }

            // Mode 1: no occurrence dates available from caller — pass nil
            let batchItems = eventIds.map { (identifier: $0, occurrenceDate: nil as Date?) }
            return try await deleteEventsWithSpan(
                items: batchItems, spanStr: spanStr, mode: "by_event_ids"
            )

        } else if let calendarName = arguments["calendar_name"]?.stringValue {
            // Mode 2: Delete by calendar + date range
            let calendarSource = arguments["calendar_source"]?.stringValue
            let beforeDate: Date? = try arguments["before_date"]?.stringValue.map { try parseFlexibleDate($0) }
            let afterDate: Date? = try arguments["after_date"]?.stringValue.map { try parseFlexibleDate($0) }

            if beforeDate == nil && afterDate == nil {
                throw ToolError.invalidParameter("At least one of before_date or after_date is required for calendar-based deletion")
            }

            // Determine search range
            let searchStart = afterDate ?? Date.distantPast
            let searchEnd = beforeDate ?? Date.distantFuture

            let events = try await eventKitManager.listEvents(
                startDate: searchStart,
                endDate: searchEnd,
                calendarName: calendarName,
                calendarSource: calendarSource
            )

            if dryRun {
                let preview = events.map { event -> [String: Any] in
                    [
                        "event_id": event.eventIdentifier ?? "",
                        "title": event.title ?? "",
                        "start_date_local": localDateFormatter.string(from: event.startDate),
                        "end_date_local": localDateFormatter.string(from: event.endDate),
                        "calendar": event.calendar.title
                    ]
                }
                var response: [String: Any] = [
                    "dry_run": true,
                    "mode": "by_date_range",
                    "calendar": calendarName,
                    "total": events.count,
                    "events_to_delete": preview,
                    "message": "Set dry_run=false to execute deletion"
                ]
                if let afterDate = afterDate { response["after_date"] = localDateFormatter.string(from: afterDate) }
                if let beforeDate = beforeDate { response["before_date"] = localDateFormatter.string(from: beforeDate) }
                return try formatJSON(response)
            }

            // Build items with per-occurrence dates (supports multiple occurrences of same series)
            let batchItems: [(identifier: String, occurrenceDate: Date?)] = events.compactMap { event in
                guard let eid = event.eventIdentifier else { return nil }
                return (identifier: eid, occurrenceDate: event.startDate)
            }

            return try await deleteEventsWithSpan(
                items: batchItems, spanStr: spanStr, mode: "by_date_range",
                extraFields: ["calendar": calendarName]
            )

        } else {
            throw ToolError.invalidParameter("Either event_ids or calendar_name (with before_date/after_date) is required")
        }
    }

    /// Feature 9: Find duplicate events across calendars
    private func handleFindDuplicateEvents(arguments: [String: Value]) async throws -> String {
        guard let startStr = arguments["start_date"]?.stringValue else {
            throw ToolError.invalidParameter("start_date is required")
        }
        let startDate = try parseFlexibleDate(startStr)
        guard let endStr = arguments["end_date"]?.stringValue else {
            throw ToolError.invalidParameter("end_date is required")
        }
        let endDate = try parseFlexibleDate(endStr)

        var calendarNames: [String]?
        if let namesArray = arguments["calendar_names"]?.arrayValue {
            calendarNames = namesArray.compactMap { $0.stringValue }
            if calendarNames?.isEmpty == true {
                calendarNames = nil
            }
        }

        let toleranceMinutes = arguments["tolerance_minutes"]?.intValue ?? 5

        let duplicates = try await eventKitManager.findDuplicateEvents(
            calendarNames: calendarNames,
            startDate: startDate,
            endDate: endDate,
            toleranceMinutes: toleranceMinutes
        )

        let result = duplicates.map { pair -> [String: Any] in
            [
                "event1": [
                    "id": pair.event1Id,
                    "title": pair.event1Title,
                    "calendar": pair.event1Calendar,
                    "start_date": dateFormatter.string(from: pair.event1StartDate),
                    "start_date_local": localDateFormatter.string(from: pair.event1StartDate)
                ],
                "event2": [
                    "id": pair.event2Id,
                    "title": pair.event2Title,
                    "calendar": pair.event2Calendar,
                    "start_date": dateFormatter.string(from: pair.event2StartDate),
                    "start_date_local": localDateFormatter.string(from: pair.event2StartDate)
                ],
                "time_difference_seconds": pair.timeDifferenceSeconds
            ]
        }

        let response: [String: Any] = [
            "search_range": [
                "start": dateFormatter.string(from: startDate),
                "start_local": localDateFormatter.string(from: startDate),
                "end": dateFormatter.string(from: endDate),
                "end_local": localDateFormatter.string(from: endDate)
            ],
            "calendars_checked": calendarNames ?? ["all calendars"],
            "tolerance_minutes": toleranceMinutes,
            "duplicate_count": duplicates.count,
            "duplicates": result
        ]
        return try formatJSON(response)
    }

    // MARK: - Event Formatting

    /// Shared event dict builder for all event-returning handlers.
    /// Includes attendees and organizer when present.
    private func formatEventDict(_ event: EKEvent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "start_date": dateFormatter.string(from: event.startDate),
            "start_date_local": formatLocal(event.startDate, in: event.timeZone),
            "end_date": dateFormatter.string(from: event.endDate),
            "end_date_local": formatLocal(event.endDate, in: event.timeZone),
            "timezone": (event.timeZone ?? TimeZone.current).identifier,
            "is_all_day": event.isAllDay,
            "calendar": event.calendar.title
        ]
        if let notes = event.notes { dict["notes"] = notes }
        if let location = event.location { dict["location"] = location }
        if let url = event.url { dict["url"] = url.absoluteString }
        if event.hasRecurrenceRules, let rules = event.recurrenceRules {
            dict["is_recurring"] = true
            dict["recurrence_rules"] = rules.map { formatRecurrenceRule($0) }
        }
        if let structured = event.structuredLocation {
            var locDict: [String: Any] = ["title": structured.title ?? ""]
            if let geo = structured.geoLocation {
                locDict["latitude"] = geo.coordinate.latitude
                locDict["longitude"] = geo.coordinate.longitude
            }
            if structured.radius > 0 { locDict["radius"] = structured.radius }
            dict["structured_location"] = locDict
        }
        // Attendees and organizer (read-only from EventKit)
        let (attendees, organizer) = formatAttendeesInfo(event)
        if let attendees = attendees, !attendees.isEmpty {
            dict["attendees"] = attendees
        }
        if let organizer = organizer {
            dict["organizer"] = organizer
        }
        return dict
    }

    // MARK: - Helpers

    /// Convert EKSourceType to human-readable string
    private func sourceTypeString(_ sourceType: EKSourceType) -> String {
        switch sourceType {
        case .local: return "Local"
        case .exchange: return "Exchange"
        case .calDAV: return "CalDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "Subscribed"
        case .birthdays: return "Birthdays"
        @unknown default: return "Unknown"
        }
    }

    /// Parse flexible date formats, supporting:
    /// 1. Full ISO8601: "2026-02-06T14:00:00+08:00"
    /// 2. ISO8601 without timezone: "2026-02-06T14:00:00" (assumes system timezone)
    /// 3. Date only: "2026-02-06" (00:00:00 system timezone)
    /// 4. Time only: "14:00" or "14:00:00" (today at that time)
    /// Parse a flexible date string. When `defaultTimezone` is provided and the
    /// string has no explicit offset, interpret the time in that timezone instead
    /// of the system timezone. Strings with explicit offsets (+XX:XX or Z) are
    /// always parsed correctly regardless of this parameter.
    private func parseFlexibleDate(_ string: String, defaultTimezone: TimeZone? = nil) throws -> Date {
        // 1. Full ISO8601 (with timezone) — offset is explicit, no ambiguity
        if let date = dateFormatter.date(from: string) {
            return date
        }

        let tz = defaultTimezone ?? TimeZone.current

        // 2. ISO8601 without timezone (e.g., "2026-02-06T14:00:00")
        if string.contains("T") && !string.contains("+") && !string.contains("Z") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = tz
            if let date = formatter.date(from: string) {
                return date
            }
        }

        // 3. Date only (e.g., "2026-02-06")
        if string.count == 10 && string.contains("-") && !string.contains("T") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = tz
            if let date = formatter.date(from: string) {
                return date
            }
        }

        // 4. Time only (e.g., "14:00" or "14:00:00")
        if !string.contains("-") && string.contains(":") {
            let components = string.split(separator: ":")
            if components.count >= 2,
               let hour = Int(components[0]),
               let minute = Int(components[1]) {
                let second = components.count >= 3 ? Int(components[2]) ?? 0 : 0
                var cal = Calendar.current
                cal.timeZone = tz
                let now = Date()
                var dc = cal.dateComponents([.year, .month, .day], from: now)
                dc.hour = hour
                dc.minute = minute
                dc.second = second
                if let date = cal.date(from: dc) {
                    return date
                }
            }
        }

        throw ToolError.invalidParameter("'\(string)' is not a valid date. Supported formats: ISO8601 (2026-02-06T14:00:00+08:00), datetime (2026-02-06T14:00:00), date (2026-02-06), time (14:00)")
    }

    /// Get date range for quick time shortcuts
    /// - Parameters:
    ///   - shortcut: The time range shortcut (today, this_week, etc.)
    ///   - weekStartsOn: First day of week setting ("system", "monday", "sunday", "saturday")
    /// - Returns: Tuple of (start date, end date, effective week start day name)
    private func getDateRange(for shortcut: String, weekStartsOn: String = "system") -> (start: Date, end: Date, effectiveWeekStart: String) {
        var calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Determine effective first weekday
        let effectiveWeekStart: String
        switch weekStartsOn {
        case "monday":
            calendar.firstWeekday = 2
            effectiveWeekStart = "monday"
        case "sunday":
            calendar.firstWeekday = 1
            effectiveWeekStart = "sunday"
        case "saturday":
            calendar.firstWeekday = 7
            effectiveWeekStart = "saturday"
        default: // "system"
            // Keep system default (Calendar.current.firstWeekday)
            switch calendar.firstWeekday {
            case 1: effectiveWeekStart = "sunday"
            case 2: effectiveWeekStart = "monday"
            case 7: effectiveWeekStart = "saturday"
            default: effectiveWeekStart = "day_\(calendar.firstWeekday)"
            }
        }

        switch shortcut {
        case "today":
            return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday)!, effectiveWeekStart)
        case "tomorrow":
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            return (tomorrow, calendar.date(byAdding: .day, value: 1, to: tomorrow)!, effectiveWeekStart)
        case "this_week":
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return (weekStart, calendar.date(byAdding: .day, value: 7, to: weekStart)!, effectiveWeekStart)
        case "next_week":
            let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeekStart)!
            return (nextWeekStart, calendar.date(byAdding: .day, value: 7, to: nextWeekStart)!, effectiveWeekStart)
        case "this_month":
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return (monthStart, calendar.date(byAdding: .month, value: 1, to: monthStart)!, effectiveWeekStart)
        case "next_7_days":
            return (startOfToday, calendar.date(byAdding: .day, value: 7, to: startOfToday)!, effectiveWeekStart)
        case "next_30_days":
            return (startOfToday, calendar.date(byAdding: .day, value: 30, to: startOfToday)!, effectiveWeekStart)
        default:
            // Default to today
            return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday)!, effectiveWeekStart)
        }
    }

    // MARK: - Recurrence & Location Helpers

    private func parseRecurrenceRule(from arguments: [String: Value], defaultTimezone: TimeZone? = nil) throws -> RecurrenceRuleInput? {
        guard let recurrenceDict = arguments["recurrence"]?.objectValue else { return nil }

        guard let freqStr = recurrenceDict["frequency"]?.stringValue else {
            throw ToolError.invalidParameter("recurrence.frequency is required")
        }

        let frequency: RecurrenceRuleInput.Frequency
        switch freqStr {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: throw ToolError.invalidParameter("Invalid frequency: \(freqStr). Use daily/weekly/monthly/yearly.")
        }

        let interval = recurrenceDict["interval"]?.intValue ?? 1
        let endDate: Date? = try recurrenceDict["end_date"]?.stringValue.map { try parseFlexibleDate($0, defaultTimezone: defaultTimezone) }
        let occurrenceCount = recurrenceDict["occurrence_count"]?.intValue

        var daysOfWeek: [Int]?
        if let days = recurrenceDict["days_of_week"]?.arrayValue {
            daysOfWeek = try days.enumerated().map { idx, v in
                guard let n = v.intValue else {
                    throw ToolError.invalidParameter("recurrence.days_of_week[\(idx)] must be an integer 1-7")
                }
                guard (1...7).contains(n) else {
                    throw ToolError.invalidParameter("recurrence.days_of_week[\(idx)] must be in range 1-7 (1=Sunday, 7=Saturday), got \(n)")
                }
                return n
            }
        }

        var daysOfMonth: [Int]?
        if let days = recurrenceDict["days_of_month"]?.arrayValue {
            daysOfMonth = try days.enumerated().map { idx, v in
                guard let n = v.intValue else {
                    throw ToolError.invalidParameter("recurrence.days_of_month[\(idx)] must be an integer")
                }
                guard (1...31).contains(n) else {
                    throw ToolError.invalidParameter("recurrence.days_of_month[\(idx)] must be in range 1-31, got \(n)")
                }
                return n
            }
        }

        return RecurrenceRuleInput(
            frequency: frequency,
            interval: interval,
            endDate: endDate,
            occurrenceCount: occurrenceCount,
            daysOfWeek: daysOfWeek,
            daysOfMonth: daysOfMonth
        )
    }

    private func parseStructuredLocation(from arguments: [String: Value]) -> StructuredLocationInput? {
        guard let dict = arguments["structured_location"]?.objectValue else { return nil }
        guard let title = dict["title"]?.stringValue else { return nil }
        return StructuredLocationInput(
            title: title,
            latitude: dict["latitude"]?.doubleValue,
            longitude: dict["longitude"]?.doubleValue,
            radius: dict["radius"]?.doubleValue
        )
    }

    private func parseTimezone(from arguments: [String: Value]) throws -> TimeZone? {
        guard let tzString = arguments["timezone"]?.stringValue else { return nil }
        guard let tz = TimeZone(identifier: tzString) else {
            throw ToolError.invalidParameter("Invalid timezone identifier: '\(tzString)'. Use IANA format (e.g., 'Europe/Berlin', 'America/New_York', 'Asia/Taipei').")
        }
        return tz
    }

    private func parseLocationTrigger(from arguments: [String: Value]) throws -> LocationTriggerInput? {
        guard let dict = arguments["location_trigger"]?.objectValue else { return nil }
        guard let title = dict["title"]?.stringValue else {
            throw ToolError.invalidParameter("location_trigger.title is required")
        }
        guard let lat = dict["latitude"]?.doubleValue else {
            throw ToolError.invalidParameter("location_trigger.latitude is required")
        }
        guard let lon = dict["longitude"]?.doubleValue else {
            throw ToolError.invalidParameter("location_trigger.longitude is required")
        }
        let radius = dict["radius"]?.doubleValue ?? 100
        let proximityStr = dict["proximity"]?.stringValue ?? "enter"
        let proximity: EKAlarmProximity = proximityStr == "leave" ? .leave : .enter

        return LocationTriggerInput(
            title: title, latitude: lat, longitude: lon,
            radius: radius, proximity: proximity
        )
    }

    private func formatRecurrenceRule(_ rule: EKRecurrenceRule) -> [String: Any] {
        var dict: [String: Any] = [
            "frequency": ["daily", "weekly", "monthly", "yearly"][rule.frequency.rawValue],
            "interval": rule.interval
        ]
        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate {
                dict["end_date"] = localDateFormatter.string(from: endDate)
            } else if end.occurrenceCount > 0 {
                dict["occurrence_count"] = end.occurrenceCount
            }
        }
        if let days = rule.daysOfTheWeek {
            dict["days_of_week"] = days.map { $0.dayOfTheWeek.rawValue }
        }
        if let days = rule.daysOfTheMonth {
            dict["days_of_month"] = days.map { $0.intValue }
        }
        return dict
    }

    // MARK: - Tag Utilities

    /// Extract #tags from notes string, returning (clean notes without tag line, array of tags)
    private func extractTags(from notes: String?) -> (cleanNotes: String?, tags: [String]) {
        guard let notes = notes, !notes.isEmpty else {
            return (nil, [])
        }

        // Tags are stored as a line of #hashtags (typically the last line)
        let tagPattern = #"#(\S+)"#
        let regex = try! NSRegularExpression(pattern: tagPattern)

        // Split into lines and find the tag line (a line where ALL non-whitespace content is #tags)
        let lines = notes.components(separatedBy: "\n")
        var tagLine: String?
        var tagLineIndex: Int?

        // Search from the end for a line that is entirely #tags
        let tagLinePattern = #"^\s*(#\S+\s*)+$"#
        let tagLineRegex = try! NSRegularExpression(pattern: tagLinePattern)

        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            if tagLineRegex.firstMatch(in: line, range: range) != nil {
                tagLine = line
                tagLineIndex = i
            }
            break  // Only check the last non-empty line
        }

        guard let foundTagLine = tagLine, let foundIndex = tagLineIndex else {
            return (notes, [])
        }

        // Extract individual tags
        let range = NSRange(foundTagLine.startIndex..., in: foundTagLine)
        let matches = regex.matches(in: foundTagLine, range: range)
        let tags = matches.compactMap { match -> String? in
            guard let tagRange = Range(match.range(at: 1), in: foundTagLine) else { return nil }
            return String(foundTagLine[tagRange])
        }

        if tags.isEmpty {
            return (notes, [])
        }

        // Rebuild notes without the tag line
        var cleanLines = lines
        cleanLines.remove(at: foundIndex)
        // Remove trailing empty lines
        while let last = cleanLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cleanLines.removeLast()
        }
        let cleanNotes = cleanLines.isEmpty ? nil : cleanLines.joined(separator: "\n")

        return (cleanNotes, tags)
    }

    /// Build notes string by combining user notes with tags
    private func buildNotesWithTags(notes: String?, tags: [String]) -> String? {
        let cleanTags = tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }

        if cleanTags.isEmpty {
            return notes
        }

        let tagLine = cleanTags.map { "#\($0)" }.joined(separator: " ")

        if let notes = notes, !notes.isEmpty {
            return "\(notes)\n\(tagLine)"
        } else {
            return tagLine
        }
    }

    /// Merge tags into existing notes: remove old tag line, append new tags
    private func mergeTagsIntoNotes(existingNotes: String?, newTags: [String]?, clearTags: Bool) -> String? {
        let (cleanNotes, _) = extractTags(from: existingNotes)

        if clearTags {
            return cleanNotes
        }

        guard let tags = newTags, !tags.isEmpty else {
            return existingNotes  // No tag change requested, keep as-is
        }

        return buildNotesWithTags(notes: cleanNotes, tags: tags)
    }

}

// MARK: - Tool Error

enum ToolError: LocalizedError {
    case invalidParameter(_ message: String)
    case unknownTool(_ name: String)

    var errorDescription: String? {
        switch self {
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}
