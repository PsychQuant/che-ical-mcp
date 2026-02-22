import CoreLocation
import EventKit
import Foundation
import MCP

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
                description: "Update an existing calendar event. When changing the event date, providing only start_time will automatically preserve the original duration.",
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
                        ])
                    ]),
                    "required": .array([.string("event_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "delete_event",
                description: "Delete a calendar event.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_id": .object(["type": .string("string"), "description": .string("The event identifier")]),
                        "span": .object(["type": .string("string"), "description": .string("For recurring events: 'this' or 'future'")])
                    ]),
                    "required": .array([.string("event_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
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
                description: "Search reminders by keyword(s) in title or notes. Supports single keyword or multiple keywords with AND/OR matching.",
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
                description: "Search events by keyword(s) in title, notes, or location. Supports single keyword or multiple keywords with AND/OR matching. Without date range, searches all events (may be slow for large calendars).",
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
                description: "PREFERRED: Create multiple events in a single call. Use this instead of calling create_event multiple times - it's faster and more reliable. Returns detailed results for each event.",
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
                            "enum": .array([.string("this"), .string("future")]),
                            "description": .string("For recurring events: 'this' (default) deletes only this occurrence, 'future' deletes this and all future occurrences")
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
                                    "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google')")])
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
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    private func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
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
        return formatJSON(result)
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
            return "Skipped (duplicate): calendar \"\(result.calendar.title)\" already exists (ID: \(result.calendar.calendarIdentifier))"
        }
        return "Created calendar: \(result.calendar.title) (ID: \(result.calendar.calendarIdentifier))"
    }

    private func handleDeleteCalendar(arguments: [String: Value]) async throws -> String {
        guard let id = arguments["id"]?.stringValue else {
            throw ToolError.invalidParameter("id is required")
        }
        try await eventKitManager.deleteCalendar(identifier: id)
        return "Calendar deleted successfully"
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

        let result = events.map { event -> [String: Any] in
            var dict: [String: Any] = [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "start_date": dateFormatter.string(from: event.startDate),
                "start_date_local": localDateFormatter.string(from: event.startDate),
                "end_date": dateFormatter.string(from: event.endDate),
                "end_date_local": localDateFormatter.string(from: event.endDate),
                "timezone": TimeZone.current.identifier,
                "is_all_day": event.isAllDay,
                "calendar": event.calendar.title
            ]
            if let notes = event.notes { dict["notes"] = notes }
            if let location = event.location { dict["location"] = location }
            if let url = event.url { dict["url"] = url.absoluteString }
            if event.hasRecurrenceRules, let rules = event.recurrenceRules {
                dict["is_recurring"] = true
                dict["recurrence_rules"] = rules.map { self.formatRecurrenceRule($0) }
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
            return dict
        }

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
        return formatJSON(response)
    }

    private func handleCreateEvent(arguments: [String: Value]) async throws -> String {
        guard let title = arguments["title"]?.stringValue else {
            throw ToolError.invalidParameter("title is required")
        }
        guard let startStr = arguments["start_time"]?.stringValue else {
            throw ToolError.invalidParameter("start_time is required")
        }
        let startDate = try parseFlexibleDate(startStr)
        guard let endStr = arguments["end_time"]?.stringValue else {
            throw ToolError.invalidParameter("end_time is required")
        }
        let endDate = try parseFlexibleDate(endStr)

        let notes = arguments["notes"]?.stringValue
        let location = arguments["location"]?.stringValue
        let url = arguments["url"]?.stringValue
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let isAllDay = arguments["all_day"]?.boolValue ?? false

        var alarmOffsets: [Int]?
        if let alarmsArray = arguments["alarms_minutes_offsets"]?.arrayValue {
            alarmOffsets = alarmsArray.compactMap { $0.intValue }
        }

        let recurrenceRule = try parseRecurrenceRule(from: arguments)
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
            structuredLocation: structuredLocation
        )

        if result.isDuplicate {
            return "Skipped (duplicate): \(result.event.title ?? title) already exists (ID: \(result.event.eventIdentifier ?? "unknown"))"
        }
        return "Created event: \(result.event.title ?? title) (ID: \(result.event.eventIdentifier ?? "unknown"))"
    }

    private func handleUpdateEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }

        let title = arguments["title"]?.stringValue
        let startDate: Date? = try arguments["start_time"]?.stringValue.map { try parseFlexibleDate($0) }
        let endDate: Date? = try arguments["end_time"]?.stringValue.map { try parseFlexibleDate($0) }
        let notes = arguments["notes"]?.stringValue
        let location = arguments["location"]?.stringValue
        let url = arguments["url"]?.stringValue
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let isAllDay = arguments["all_day"]?.boolValue

        let recurrenceRule = try parseRecurrenceRule(from: arguments)
        let clearRecurrence = arguments["clear_recurrence"]?.boolValue ?? false
        let structuredLocation = parseStructuredLocation(from: arguments)

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
            recurrenceRule: recurrenceRule,
            clearRecurrence: clearRecurrence,
            structuredLocation: structuredLocation
        )

        return "Updated event: \(event.title ?? "")"
    }

    private func handleDeleteEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }

        let spanStr = arguments["span"]?.stringValue ?? "this"
        let span: EKSpan = spanStr == "future" ? .futureEvents : .thisEvent

        try await eventKitManager.deleteEvent(identifier: eventId, span: span)
        return "Event deleted successfully"
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
                reminder.dueDateComponents?.date.map { $0 < now } == true
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
                let d1 = r1.dueDateComponents?.date
                let d2 = r2.dueDateComponents?.date
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

        let result = reminders.map { reminder -> [String: Any] in
            var dict: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "is_completed": reminder.isCompleted,
                "priority": reminder.priority,
                "calendar": reminder.calendar.title,
                "timezone": TimeZone.current.identifier
            ]
            if let notes = reminder.notes { dict["notes"] = notes }
            if let dueDate = reminder.dueDateComponents?.date {
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
        return formatJSON(response)
    }

    private func handleCreateReminder(arguments: [String: Value]) async throws -> String {
        guard let title = arguments["title"]?.stringValue else {
            throw ToolError.invalidParameter("title is required")
        }

        let notes = arguments["notes"]?.stringValue
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
            return "Skipped (duplicate): \(result.reminder.title ?? title) already exists (ID: \(result.reminder.calendarItemIdentifier))"
        }
        return "Created reminder: \(result.reminder.title ?? title) (ID: \(result.reminder.calendarItemIdentifier))"
    }

    private func handleUpdateReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }

        let title = arguments["title"]?.stringValue
        let notes = arguments["notes"]?.stringValue
        let dueDate: Date? = try arguments["due_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let priority = arguments["priority"]?.intValue
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let locationTrigger = try parseLocationTrigger(from: arguments)
        let clearLocationTrigger = arguments["clear_location_trigger"]?.boolValue ?? false

        let reminder = try await eventKitManager.updateReminder(
            identifier: reminderId,
            title: title,
            notes: notes,
            dueDate: dueDate,
            priority: priority,
            calendarName: calendarName,
            calendarSource: calendarSource,
            locationTrigger: locationTrigger,
            clearLocationTrigger: clearLocationTrigger
        )

        return "Updated reminder: \(reminder.title ?? "")"
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

        let status = reminder.isCompleted ? "completed" : "incomplete"
        return "Reminder marked as \(status): \(reminder.title ?? "")"
    }

    private func handleDeleteReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }

        try await eventKitManager.deleteReminder(identifier: reminderId)
        return "Reminder deleted successfully"
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

        return "Updated calendar: \(calendar.title) (ID: \(calendar.calendarIdentifier))"
    }

    private func handleSearchReminders(arguments: [String: Value]) async throws -> String {
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
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let completed = arguments["completed"]?.boolValue

        let reminders = try await eventKitManager.searchReminders(
            keywords: keywords,
            matchMode: matchMode,
            calendarName: calendarName,
            calendarSource: calendarSource,
            completed: completed
        )

        let result = reminders.map { reminder -> [String: Any] in
            var dict: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "is_completed": reminder.isCompleted,
                "priority": reminder.priority,
                "calendar": reminder.calendar.title,
                "timezone": TimeZone.current.identifier
            ]
            if let notes = reminder.notes { dict["notes"] = notes }
            if let dueDate = reminder.dueDateComponents?.date {
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

        let response: [String: Any] = [
            "keywords": keywords,
            "match_mode": matchMode,
            "result_count": reminders.count,
            "reminders": result
        ]
        return formatJSON(response)
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
                let batchDueDate: Date? = try reminderDict["due_date"]?.stringValue.map { try parseFlexibleDate($0) }
                let result = try await eventKitManager.createReminder(
                    title: title,
                    notes: reminderDict["notes"]?.stringValue,
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
        return formatJSON(response)
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

        return formatJSON(response)
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
        let startDate: Date? = try arguments["start_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let endDate: Date? = try arguments["end_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let events = try await eventKitManager.searchEvents(
            keywords: keywords,
            matchMode: matchMode,
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        let result = events.map { event -> [String: Any] in
            var dict: [String: Any] = [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "start_date": dateFormatter.string(from: event.startDate),
                "start_date_local": localDateFormatter.string(from: event.startDate),
                "end_date": dateFormatter.string(from: event.endDate),
                "end_date_local": localDateFormatter.string(from: event.endDate),
                "timezone": TimeZone.current.identifier,
                "is_all_day": event.isAllDay,
                "calendar": event.calendar.title
            ]
            if let notes = event.notes { dict["notes"] = notes }
            if let location = event.location { dict["location"] = location }
            if let url = event.url { dict["url"] = url.absoluteString }
            if event.hasRecurrenceRules, let rules = event.recurrenceRules {
                dict["is_recurring"] = true
                dict["recurrence_rules"] = rules.map { self.formatRecurrenceRule($0) }
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
            return dict
        }

        let response: [String: Any] = [
            "keywords": keywords,
            "match_mode": matchMode,
            "result_count": events.count,
            "events": result
        ]
        return formatJSON(response)
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

        let result = events.map { event -> [String: Any] in
            var dict: [String: Any] = [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "start_date": dateFormatter.string(from: event.startDate),
                "start_date_local": localDateFormatter.string(from: event.startDate),
                "end_date": dateFormatter.string(from: event.endDate),
                "end_date_local": localDateFormatter.string(from: event.endDate),
                "timezone": TimeZone.current.identifier,
                "is_all_day": event.isAllDay,
                "calendar": event.calendar.title
            ]
            if let notes = event.notes { dict["notes"] = notes }
            if let location = event.location { dict["location"] = location }
            if let url = event.url { dict["url"] = url.absoluteString }
            if event.hasRecurrenceRules, let rules = event.recurrenceRules {
                dict["is_recurring"] = true
                dict["recurrence_rules"] = rules.map { self.formatRecurrenceRule($0) }
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
            return dict
        }

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
        return formatJSON(response)
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
            guard let startStr = eventDict["start_time"]?.stringValue else {
                results.append(["index": index, "success": false, "error": "start_time is required"])
                continue
            }
            let startDate: Date
            do {
                startDate = try parseFlexibleDate(startStr)
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
                endDate = try parseFlexibleDate(endStr)
            } catch {
                results.append(["index": index, "success": false, "error": error.localizedDescription])
                continue
            }

            do {
                // Parse recurrence and structured location from batch item
                let batchRecurrence = try parseRecurrenceRule(from: eventDict)
                let batchStructuredLocation = parseStructuredLocation(from: eventDict)

                let result = try await eventKitManager.createEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    notes: eventDict["notes"]?.stringValue,
                    location: eventDict["location"]?.stringValue,
                    url: nil,
                    calendarName: eventDict["calendar_name"]?.stringValue,
                    calendarSource: eventDict["calendar_source"]?.stringValue,
                    isAllDay: eventDict["all_day"]?.boolValue ?? false,
                    alarmOffsets: nil,
                    recurrenceRule: batchRecurrence,
                    structuredLocation: batchStructuredLocation
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
        return formatJSON(response)
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

        let result = conflicts.map { event -> [String: Any] in
            var dict: [String: Any] = [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "start_date": dateFormatter.string(from: event.startDate),
                "start_date_local": localDateFormatter.string(from: event.startDate),
                "end_date": dateFormatter.string(from: event.endDate),
                "end_date_local": localDateFormatter.string(from: event.endDate),
                "timezone": TimeZone.current.identifier,
                "calendar": event.calendar.title
            ]
            if let location = event.location { dict["location"] = location }
            return dict
        }

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
        return formatJSON(response)
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

        let action = deleteOriginal ? "Moved" : "Copied"
        return "\(action) event '\(newEvent.title ?? "")' to calendar '\(targetCalendar)' (New ID: \(newEvent.eventIdentifier ?? "unknown"))"
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
        return formatJSON(response)
    }

    /// Feature 8: Delete multiple events at once (by IDs or by date range)
    private func handleDeleteEventsBatch(arguments: [String: Value]) async throws -> String {
        let dryRun = arguments["dry_run"]?.boolValue ?? true
        let spanStr = arguments["span"]?.stringValue ?? "this"
        let span: EKSpan = spanStr == "future" ? .futureEvents : .thisEvent

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
                return formatJSON(response)
            }

            let result = try await eventKitManager.deleteEventsBatch(identifiers: eventIds, span: span)
            var response: [String: Any] = [
                "dry_run": false,
                "mode": "by_event_ids",
                "total": eventIds.count,
                "succeeded": result.successCount,
                "failed": result.failedCount,
                "span": spanStr
            ]
            if !result.failures.isEmpty {
                response["failures"] = result.failures.map { ["event_id": $0.identifier, "error": $0.error] }
            }
            return formatJSON(response)

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
                return formatJSON(response)
            }

            let eventIds = events.compactMap { $0.eventIdentifier }
            let result = try await eventKitManager.deleteEventsBatch(identifiers: eventIds, span: span)
            var response: [String: Any] = [
                "dry_run": false,
                "mode": "by_date_range",
                "calendar": calendarName,
                "total": eventIds.count,
                "succeeded": result.successCount,
                "failed": result.failedCount,
                "span": spanStr
            ]
            if !result.failures.isEmpty {
                response["failures"] = result.failures.map { ["event_id": $0.identifier, "error": $0.error] }
            }
            return formatJSON(response)

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
        return formatJSON(response)
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
    private func parseFlexibleDate(_ string: String) throws -> Date {
        // 1. Full ISO8601 (with timezone)
        if let date = dateFormatter.date(from: string) {
            return date
        }

        // 2. ISO8601 without timezone (e.g., "2026-02-06T14:00:00")
        if string.contains("T") && !string.contains("+") && !string.contains("Z") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: string) {
                return date
            }
        }

        // 3. Date only (e.g., "2026-02-06")
        if string.count == 10 && string.contains("-") && !string.contains("T") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
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
                cal.timeZone = TimeZone.current
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

    private func parseRecurrenceRule(from arguments: [String: Value]) throws -> RecurrenceRuleInput? {
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
        let endDate: Date? = try recurrenceDict["end_date"]?.stringValue.map { try parseFlexibleDate($0) }
        let occurrenceCount = recurrenceDict["occurrence_count"]?.intValue

        var daysOfWeek: [Int]?
        if let days = recurrenceDict["days_of_week"]?.arrayValue {
            daysOfWeek = days.compactMap { $0.intValue }
        }

        var daysOfMonth: [Int]?
        if let days = recurrenceDict["days_of_month"]?.arrayValue {
            daysOfMonth = days.compactMap { $0.intValue }
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

    private func formatJSON(_ value: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            return "[]"
        }
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
