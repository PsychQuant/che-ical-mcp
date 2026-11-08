import CheMCPKit
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

    // If we have enough day-based fields, use them. #299: in the calendar the components carry,
    // else in the Gregorian calendar EventKit's components are in, never the host's region
    // calendar; the same rule as `ReminderDueInput`, `ReminderDueValue.chronologicalDate` and
    // `UndoPostStateFields`. A zone the components carry wins over the host zone.
    if dc.year != nil && dc.month != nil && dc.day != nil {
        var calendar = Calendar(identifier: dc.calendar?.identifier ?? .gregorian)
        calendar.timeZone = .current
        clean.era = dc.era
        return calendar.date(from: clean)
    }

    // Fallback: if no day-based fields, use the original .date
    return dc.date
}

/// MCP Server for EventKit integration
class CheICalMCPServer {
    private let server: Server
    private let transport: DrainingStdioTransport
    private let eventKitManager = EventKitManager.shared
    // #31: narrow `EventKitManaging` surface injected at init time so tests
    // can supply `FakeEventKitManager` for the cleanup handler without
    // having to fake the full 30-method EventKitManager surface. Production
    // uses the shared singleton (D1 in design.md: protocol covers only the
    // 3 methods the cleanup handler needs).
    private let reminderCleanupSource: any EventKitManaging
    private let eventCopySource: any EventCopySource
    private let eventWriteSource: any EventWriteSource
    private let eventDeletionSource: any EventDeletionSource
    private let calendarDeletionSource: any CalendarDeletionSource
    private let calendarWriteSource: any CalendarWriteSource
    /// #331: the date-range listing and batch deletes of `delete_events_batch`.
    private let eventBatchDeletionSource: any EventBatchDeletionSource
    private let duplicateSearchSource: any DuplicateSearchSource
    private let eventRangeReadSource: any EventRangeReadSource
    private let reminderWriteSource: any ReminderWriteSource
    private let reminderReadSource: any ReminderReadSource
    private let undoManager: CalendarUndoManager
    private let undoExecutionSource: any UndoExecutionSource
    private let reminderCompletionSource: any ReminderCompletionSource
    private let dateFormatter: ISO8601DateFormatter

    /// Local time formatter for user-friendly display. Gregorian with ASCII digits whatever the
    /// host locale (#304).
    private let localDateFormatter = DateFormatter.machineReadable("yyyy-MM-dd'T'HH:mm:ss", zone: TimeZone.current)

    /// Format a date as local time in a specific timezone (#304: Gregorian, ASCII digits)
    private func formatLocal(_ date: Date, in tz: TimeZone?) -> String {
        DateFormatter.machineReadable("yyyy-MM-dd'T'HH:mm:ss", zone: tz ?? TimeZone.current).string(from: date)
    }

    /// All available tools
    private let tools: [Tool]

    /// Constructor with per-feature test seams.
    ///
    /// `reminderCleanupSource` is the canonical example of the "narrow `*Source`
    /// protocol" DI convention (#34, see `CLAUDE.md` "Test Seam Convention"):
    /// production code passes nothing → defaults to `EventKitManager.shared`;
    /// `CleanupHandlerTests` passes a `FakeEventKitManager`. New handlers that
    /// need a test fake should add their own narrow `*Source` parameter here
    /// rather than widening `EventKitManaging`.
    init(reminderCleanupSource: any EventKitManaging = EventKitManager.shared,
         reminderReadSource: any ReminderReadSource = EventKitManager.shared,
         eventCopySource: any EventCopySource = EventKitManager.shared,
         eventWriteSource: any EventWriteSource = EventKitManager.shared,
         eventDeletionSource: any EventDeletionSource = EventKitManager.shared,
         calendarDeletionSource: any CalendarDeletionSource = EventKitManager.shared,
         calendarWriteSource: any CalendarWriteSource = EventKitManager.shared,
         eventBatchDeletionSource: any EventBatchDeletionSource = EventKitManager.shared,
         duplicateSearchSource: any DuplicateSearchSource = EventKitManager.shared,
         eventRangeReadSource: any EventRangeReadSource = EventKitManager.shared,
         reminderWriteSource: any ReminderWriteSource = EventKitManager.shared,
         undoManager: CalendarUndoManager = .shared,
         reminderCompletionSource: any ReminderCompletionSource = EventKitManager.shared,
         undoExecutionSource: any UndoExecutionSource = EventKitManager.shared) async throws {
        self.reminderCleanupSource = reminderCleanupSource
        self.reminderReadSource = reminderReadSource
        self.reminderCompletionSource = reminderCompletionSource
        self.undoManager = undoManager
        self.undoExecutionSource = undoExecutionSource
        self.reminderWriteSource = reminderWriteSource
        self.eventCopySource = eventCopySource
        self.eventWriteSource = eventWriteSource
        self.eventDeletionSource = eventDeletionSource
        self.calendarDeletionSource = calendarDeletionSource
        self.calendarWriteSource = calendarWriteSource
        self.eventBatchDeletionSource = eventBatchDeletionSource
        self.duplicateSearchSource = duplicateSearchSource
        self.eventRangeReadSource = eventRangeReadSource

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        // Define all tools
        tools = Self.defineTools()

        // Create server with tools capability
        server = Server(
            name: AppVersion.mcpServerName,
            version: AppVersion.current,
            capabilities: .init(tools: .init())
        )

        // #345: answer requests already read before exiting on stdin EOF.
        transport = DrainingStdioTransport()

        // Register handlers
        await registerHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    // Exposed as `internal` (not `private`) so tests can enumerate the tool
    // list and verify every declared name is dispatched in `executeToolCall`.
    static func defineTools() -> [Tool] {
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
                            "enum": .array([.string("event"), .string("reminder")]),
                            "description": .string("Filter by type: 'event' or 'reminder'; anything else is refused. If not provided, returns all calendars.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "create_calendar",
                description: "Create a new calendar or reminder list. If saving a reminder list reports an error but the list turns out to be saved, the call succeeds; when the store then holds some of its fields differently, the response's store_differs lists their keys, from `title` and `account`, and note says to check the list and that creating it again with the same parameters may make a second copy.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("The name of the calendar, 1 to 255 characters and not only whitespace. The limit is not a promise that a long title stays: see #449.")
                        ]),
                        "type": .object([
                            "type": .string("string"),
                            "enum": .array([.string("event"), .string("reminder")]),
                            "description": .string("Type of calendar: 'event' or 'reminder'; anything else is refused")
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
                description: "Delete a calendar (or reminder list) by its identifier; not undoable. With require_empty true, a calendar that holds any event, or a list that holds any reminder (completed ones included), is refused and nothing is deleted; so is one whose reminders cannot be counted or that allows neither kind. What is not seen, and is deleted with the calendar: an event more than about 200 years from now (EventKit has no query for every event of a calendar), for example one typed with the year 0026; an event still on the server and not yet synced to this Mac (the check reads this Mac's calendar data); and a write by another app or a sync between the check and the deletion (no write by this server process can land there, except one that failed earlier and is still pending, which this check does not see). A passed check answers {action, id, checked_empty: true} plus searched_from and searched_to (the window searched, local time) for a calendar, or reminders_found: 0 for a list; a calendar that allows both kinds is checked for both and answers with both. Without require_empty the answer is {action, id}, as before. Pass only id and require_empty; null or another key is refused. If deleting a reminder list fails, the list and every reminder in it may still be deleted by the next save this server makes, with no undo record of its own: the error says so.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The calendar identifier")
                        ]),
                        "require_empty": .object([
                            "type": .string("boolean"),
                            "description": .string("Refuse to delete when the calendar holds events within searched_from..searched_to (about 200 years each side of now), or the list holds reminders. Default false.")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "update_calendar",
                description: "Update a calendar's properties (rename or change color). If saving a reminder list fails, the change may still be written by the next save this server makes: the error says so.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("The calendar identifier")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("New calendar name, 1 to 255 characters and not only whitespace. The limit is not a promise that a long title stays: see #449.")
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "description": .string("New hex color code (e.g., '#FF5733')")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Event Tools
            Tool(
                name: "list_events",
                description: "List calendar events in a date range with optional filtering, sorting, and limiting. Supports flexible date formats: ISO8601 (2026-01-30T00:00:00+08:00), datetime (2026-01-30T00:00:00), date only (2026-01-30), or time only (14:00). Any date range is searched in full, in queries of at most four years each (EventKit returns only the first four years of one longer query); a range longer than 146,000 days (about 400 years) is refused with an error. Over a range longer than 1462 days, a read that passes about 200,000 event occurrences (about 2,000 a year over 100 years, all calendars read together; checked after each 1460-day part, which is read whole; limit does not lift it) stops with an error and returns nothing: narrow the range or give calendar_name. Over such a range, without limit at most 500 events are returned, the first in the requested sort, with metadata.default_limit. truncated: true whenever fewer events are returned than event_count, a limit's cut included; event_count is still the total. Each event reports item_timezone (the event's own time zone; null when floating, all-day events included); timezone is the event's time zone, or the host time zone when the event is floating; the *_local strings are in display_timezone when given, otherwise in timezone. Outside detail_level summary each event lists its time-based alarms as alarms, the shape list_reminders uses (relative minutes_before, measured from the start: positive = before the start, negative = after; or absolute absolute_date, with absolute_date_local in the zone of the other *_local strings; [] when none; location alarms are not listed). An occurrence reports the series' alarms unless it was edited on its own.",
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
                            "description": .string("Maximum number of events to return, at most 10000. When omitted, all of them, except over a range longer than 1462 days: at most 500. A limit does not lift the read bound.")
                        ]),
                        "detail_level": .object([
                            "type": .string("string"),
                            "enum": .array([.string("summary"), .string("standard")]),
                            "description": .string("Response detail: 'summary' (id, title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day, calendar — plus location when set) or 'standard' (all fields, default). Use 'summary' to reduce token usage; pass an explicit 'fields' array for finer-grained selection.")
                        ]),
                        "display_timezone": .object([
                            "type": .string("string"),
                            "description": .string("IANA timezone (e.g., 'America/Los_Angeles') for *_local fields. If omitted, each event uses its own timezone.")
                        ]),
                        "fields": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Field names to include per event (e.g., ['title', 'start_date_local', 'calendar']). Overrides detail_level. 'id' always included. Available: title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day, calendar, location, notes, url, is_recurring, recurrence_rules, event_recurrence_rules, structured_location, attendees, organizer, alarms")
                        ])
                    ]),
                    "required": .array([.string("start_date"), .string("end_date")])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "create_event",
                description: "Create a new calendar event with optional reminders and recurrence.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string"), "description": .string("Event title")]),
                        "start_time": .object(["type": .string("string"), "description": .string("Start time in ISO8601 format with timezone (e.g., 2026-01-30T14:00:00+08:00). For an all-day event (all_day true) only the day counts, read in this Mac's time zone: send a date without an offset (a value with another offset is converted to this Mac's zone first, which can move it to another day; when it does, the result carries a warnings entry naming the field, its day in the written offset (written_day) and the day in this Mac's zone the request's dates are written with (host_day; a skipped duplicate writes nothing)).")]),
                        "end_time": .object(["type": .string("string"), "description": .string("End time in ISO8601 format with timezone (e.g., 2026-01-30T15:00:00+08:00). For an all-day event (all_day true) only the days count, read in this Mac's time zone: start_time names the first day; end_time is the day after the last day (exclusive, e.g. a one-night stay on 11-10 ends 11-11), the first day itself for a one-day event, or the last day at 23:59:59 as list_events returns it. Send all-day dates without an offset: a value with another offset is converted to this Mac's zone first, which can move it to another day. When it does, the event still uses this Mac's day and the result carries a warnings entry naming the field, its day in the written offset (written_day) and the day in this Mac's zone the request's dates are written with (host_day; a skipped duplicate writes nothing).")]),
                        "notes": .object(["type": .string("string"), "description": .string("Optional event notes")]),
                        "location": .object(["type": .string("string"), "description": .string("Optional event location")]),
                        "url": .object(["type": .string("string"), "description": .string("Optional event URL")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Target calendar name (use list_calendars to see available options)")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "all_day": .object(["type": .string("boolean"), "description": .string("Whether this is an all-day event. Mutually exclusive with timezone — all-day events are floating calendar days (#190). Its dates are whole days, read in this Mac's time zone: see start_time and end_time. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")]),
                        "alarms_minutes_offsets": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                            "description": .string("List of minutes before the event to trigger reminders (integers from -525600 to 525600, one year)")
                        ]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Recurrence rule. Example: {\"frequency\": \"weekly\", \"interval\": 1, \"days_of_week\": [2,6]} for every Monday and Friday. A key that is not one of this object's properties is refused and nothing is written, so a misspelled bound cannot leave the series open-ended."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1; an integer from 1 to 1000). E.g., interval=2 with frequency=weekly means every other week.")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). Giving occurrence_count too is refused.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences, an integer from 1 to 10000. Giving end_date too is refused. A yearly rule with days_of_week repeats in the start's month. With interval 1 and no days_of_month the rule refuses occurrence_count: use frequency monthly with interval 12 or end_date for those days, or yearly without days_of_week for once a year.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday); used by every frequency, and the start has to fall on one of them")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days of month to repeat (1-31), for monthly and yearly rules; refused on daily and weekly rules, which do not use them; the start has to fall on one of them")
                                ]),
                                "excluded_occurrence_dates": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string")]),
                                    "description": .string("Occurrence dates to exclude from the series at creation (max 100; same date grammar as occurrence_date - date-only values use the event timezone). Applied with best-effort all-or-nothing semantics: on any failure the new series is removed via compensating delete (rollback failure itself is reported, never silent). Each date must resolve to an occurrence generated by the rule; the first occurrence cannot be excluded. Each date is the day the occurrence starts on: an occurrence that runs past midnight is removed by the day it starts, and a date it only runs into removes the occurrence starting on that day instead, or, when none starts on it, the create is rolled back with the no-occurrence error. Only supported here and on create_events_batch.")
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
                description: "Update an existing calendar event. When changing the event date, providing only start_time keeps the original duration of a timed event; an event that is all-day after the update keeps its number of days instead (see start_time), and turning an all-day event into a timed one needs both start_time and end_time. For recurring events, use 'span' to control whether changes apply to this occurrence, future occurrences, or all. An update that touches a recurring event (any span, or adding or removing recurrence) cannot be undone with undo. The response's id is the event's identifier after the save. It changes (id_changed true, previous_id repeating the event_id you passed) in four cases only: calendar_name moves the event to a calendar in another account (an edit of one occurrence, occurrence_date with span 'this', with a new calendar is refused and writes nothing, since a new calendar moves the whole series; a calendar whose account cannot be read counts as another account); span 'future' from a later occurrence ends the series there and starts a new one, whose identifier id then is, also when event_id is the identifier of an occurrence edited on its own; span 'all' or 'future' with the identifier of an occurrence edited on its own that is the first occurrence left, after the first was deleted, gives what remains a new identifier; span 'all' through the series' identifier, when the series' first occurrence was edited on its own and still starts at its original time, or was deleted with the first occurrence left edited on its own, goes through that occurrence's identifier and answers it after the save as occurrence_id, and id changes when a new series starts there (after a deleted first occurrence). Otherwise id is event_id and id_changed is false. An edit of one occurrence (occurrence_date with span 'this') answers the series' identifier as id and adds occurrence_id, the identifier of that occurrence alone (on iCloud, the series identifier followed by /RID= and a number). Use occurrence_id with span 'this' to edit that occurrence, or span 'future' to update from it on, within the limits below. span 'all' with the identifier of an occurrence edited on its own would split the series while an earlier occurrence remains, so it is then refused and writes nothing (#416); use the id list_events shows for the occurrence that comes first in the series. A series whose first occurrence was deleted has no whole-series update unless its first occurrence left was edited on its own (#326). With span 'all' or 'future' through such an identifier, and with span 'all' through the series' identifier in the shape just named, title, notes, location and recurrence can be written (not recurrence with span 'all' after the series' first occurrence was deleted, through either identifier); start_time, end_time, all_day true, alarms, timezone, url and structured_location only in the shapes that were measured, which the refusal lists (among them: one field per call, or start_time with end_time, as a new time of day on the same date; a timed series repeating weekly on at most one day; the occurrence at its original start, edited only in title, notes, location or alarms; structured_location only while it has the series' location). all_day true there cannot be turned back through that identifier. On a series that has started, these routes take the started-series rules below (#451), as the series' identifier goes through that occurrence's own; timezone among them (#478). For anything else use span 'this', or the id of an occurrence not edited on its own. A title, notes or location the occurrence already holds is refused too, as it would reach no other occurrence, and so is a write that would start a new series from an occurrence holding its own location or alarms. With span 'this' or 'future' occurrence_date must be that occurrence's day. When occurrence_date picked one occurrence (span 'this' or 'future'), the response adds occurrence_start, the start of the occurrence occurrence_date matched, before the update, as ISO 8601 with the offset of the event's time zone, so you can check which day was edited.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_id": .object(["type": .string("string"), "description": .string("The event identifier")]),
                        "title": .object(["type": .string("string"), "description": .string("New title")]),
                        "start_time": .object(["type": .string("string"), "description": .string("New start time in ISO8601 format (e.g., 2026-01-31T14:00:00+08:00). On a recurring series that has started, with span all or span future from an occurrence that has already happened, only the time of day on that occurrence's own date may change, and from an occurrence still to come the start may not be before now; anything else is refused (#451). If only start_time is provided, a timed event keeps its duration (an event that is all-day after the update keeps the number of days its range touches, an end at exactly midnight not counting that day (the same rule as end_time), counted in this Mac's time zone; turning an all-day event into a timed one needs both start_time and end_time and is refused with only one of them). For an all-day event (all_day true) only the day counts, read in this Mac's time zone: send a date without an offset (a value with another offset is converted to this Mac's zone first, which can move it to another day; when it does, the result carries a warnings entry naming the field, its day in the written offset (written_day) and the day in this Mac's zone the request's dates are written with (host_day; a skipped duplicate writes nothing)).")]),
                        "end_time": .object(["type": .string("string"), "description": .string("New end time in ISO8601 format (e.g., 2026-01-31T15:00:00+08:00). Provide this if you want to change the event duration; turning an all-day event into a timed one needs both start_time and end_time. For an all-day event (all_day true) only the days count, read in this Mac's time zone: start_time names the first day; end_time is the day after the last day (exclusive, e.g. a one-night stay on 11-10 ends 11-11), the first day itself for a one-day event, or the last day at 23:59:59 as list_events returns it. Send all-day dates without an offset: a value with another offset is converted to this Mac's zone first, which can move it to another day. When it does, the event still uses this Mac's day and the result carries a warnings entry naming the field, its day in the written offset (written_day) and the day in this Mac's zone the request's dates are written with (host_day; a skipped duplicate writes nothing). The same rule applies whether the event is already all-day or becomes all-day in this call.")]),
                        "notes": .object(["type": .string("string"), "description": .string("New notes")]),
                        "location": .object(["type": .string("string"), "description": .string("New location")]),
                        "all_day": .object(["type": .string("boolean"), "description": .string("Set to true for all-day events, false for timed events. Its dates are whole days, read in this Mac's time zone: see start_time and end_time. false on an all-day event with new times needs both start_time and end_time. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = unchanged.")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Move event to a different calendar. A calendar in another account can give the event a new identifier: use the response's id (see id_changed).")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "url": .object(["type": .string("string"), "description": .string("Optional event URL")]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Set or replace recurrence rule; on a recurring event pass span all, or span future with occurrence_date (a rule on one occurrence, span this, is refused). With span future from a later occurrence, occurrence_count is refused, as the store counts from the start of the original series: use end_date (#451). On a series that has started, a rule from an occurrence that has already happened must keep the series' pattern (frequency, interval, days_of_week, days_of_month) with its own bound or, while the series has occurrences to come, no bound, an end_date not in the past, or an occurrence_count no smaller than the series' own (#451). Cannot be combined with clear_recurrence. Example: {\"frequency\": \"weekly\", \"interval\": 1, \"days_of_week\": [2,6]} for every Monday and Friday. A key that is not one of this object's properties is refused and nothing is written, so a misspelled bound cannot leave the series open-ended."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1; an integer from 1 to 1000)")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). A bare date stops before that day's occurrence, so to keep it pass a time after its start. Giving occurrence_count too is refused.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences, an integer from 1 to 10000. Giving end_date too is refused. A yearly rule with days_of_week repeats in the start's month. With interval 1 and no days_of_month the rule refuses occurrence_count: use frequency monthly with interval 12 or end_date for those days, or yearly without days_of_week for once a year.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday); used by every frequency, and the start has to fall on one of them")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days of month to repeat (1-31), for monthly and yearly rules; refused on daily and weekly rules, which do not use them; the start has to fall on one of them")
                                ])
                            ]),
                            "required": .array([.string("frequency")])
                        ]),
                        "alarms_minutes_offsets": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                            "description": .string("List of minutes before the event to trigger reminders (integers from -525600 to 525600, one year). Replaces all existing alarms. Use empty array [] to remove all alarms.")
                        ]),
                        "clear_recurrence": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove the recurrence rule from the event. A series takes span all, which leaves one event on its first day and deletes the other occurrences. Cannot be combined with recurrence, or with span this or future on a series; to end a series at an occurrence, pass recurrence with the series' whole rule and an end_date after that occurrence's start, with span all. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
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
                        "timezone": .object(["type": .string("string"), "description": .string("IANA timezone identifier for the event (e.g., 'Europe/Berlin', 'America/New_York'). Sets the event's display timezone. On a recurring series that has started, with span all or span future from an occurrence that has already happened, any identifier other than the event's own (item_timezone) is refused: another spelling of the same zone counts as a change, and so does any zone, this Mac's included, on an event with no zone of its own (item_timezone null). The occurrences repeat at the new zone's wall-clock time, which moved happened ones and lost the last one of a counted series (#478). From an occurrence that has already happened, the event's own identifier is not written again.")]),
                        "clear_timezone": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove per-event timezone (revert to system timezone) Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default. Refused like timezone on a recurring series that has started, whatever the zone, as a counted series lost its last occurrence (#455, #478); on a started series with no zone, from an occurrence that has already happened, it writes nothing.")
                        ]),
                        "span": .object([
                            "type": .string("string"),
                            "enum": .array([.string("this"), .string("future"), .string("all")]),
                            "description": .string("For recurring events: 'this' (default) updates only this occurrence, 'future' updates this and all future occurrences, 'all' updates the entire series")
                        ]),
                        "occurrence_date": .object([
                            "type": .string("string"),
                            "description": .string("For recurring events: the date of the specific occurrence to modify (e.g., '2026-03-28' or '2026-03-28T09:30:00+08:00'). Without an offset it is read in the event's current time zone, not in timezone (the zone the event gets); with an offset it is used as given, and its day is taken in the event's current time zone too. A floating or all-day series uses this Mac's time zone. The value names the day the occurrence starts on. An occurrence that runs past midnight is found by the day it starts on; a date or time on the following day, even a time inside that occurrence, selects the occurrence starting on that following day, if any. Required when span is 'this' or 'future' on recurring events.")
                        ])
                    ]),
                    "required": .array([.string("event_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "delete_event",
                description: "Delete a calendar event. For recurring events, use the 'span' parameter (not 'delete_scope') to control scope. When span is 'this' or 'future' on a recurring event, occurrence_date is required to identify the specific occurrence. Span 'all' through the identifier of an occurrence edited on its own would delete that occurrence only, so it is refused and deletes nothing while another occurrence remains (#416); when the series can be listed, the refusal says which id and span delete it. With span 'this' or 'future' through such an identifier occurrence_date must be that occurrence's day. Span 'all' through the series' identifier, when the series' first occurrence was edited on its own and still starts at its original time, or was deleted with the first occurrence left edited on its own, deletes the series with span 'future' from that occurrence, which removed every occurrence (measured on iCloud, open-ended series included); the response adds occurrence_id and undo_note, as that delete cannot be undone. Undo of a deleted occurrence (span 'this') restores it as a one-off event, because an occurrence cannot be put back into its series; an absolute-date alarm of the series becomes an alarm at its start. Undo of span 'future' recreates the series only when the delete started at the series' first occurrence and removed all of it; otherwise (it started at a later occurrence, the last one included, or event_id named an edited occurrence) that undo is refused and its history entry discarded, writing nothing. Undo of a whole-series delete (that case, or span 'all' outside the shape named above) recreates the series from its rules and then restores its exceptions inside the scan window (from one day before the first occurrence to the end of the rule, at most four years): an occurrence deleted on its own earlier stays deleted, one edited on its own comes back as a separate one-off event that no longer belongs to the series; the undo text says how many of each. Not restored as exceptions, and said in the text: a first occurrence edited or deleted on its own (kept from the rule, so its edit is lost or its deleted occurrence comes back), an edited occurrence moved more than a year outside the window (its slot counts as deleted), a series whose exceptions could not be listed, and a record that does not match the recreated series (none is applied); exceptions outside that window come back from the rules alone. If restoring them fails the recreated series and the one-off events are deleted again and the entry is kept for a retry; if that delete fails too, the error says so and the entry (in a batch, that member) is dropped. Undoing the earlier delete of an occurrence that the restored series already holds writes nothing and says so.",
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
                            "description": .string("For recurring events: the date of the specific occurrence to act on (e.g., '2026-03-28' or '2026-03-28T09:30:00+08:00'): the day the occurrence starts on, in the event's time zone. An occurrence that runs past midnight is found by the day it starts on; a date or time on the following day, even a time inside that occurrence, selects the occurrence starting on that following day, if any. Required when span is 'this' or 'future' on recurring events.")
                        ])
                    ]),
                    "required": .array([.string("event_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Undo/Redo Tools
            Tool(
                name: "undo",
                description: "Undo the most recent calendar or reminder operation. Returns what was undone. Refuses without writing anything when the event or reminder was changed after that operation in a way the undo would overwrite or delete, or, for a recurring event created here, when occurrences were edited on their own or could not be checked; the error names the changed fields and says what can be done. The record stays in undo_history: undo again once a changed field is changed back, or pass its id as discard_id if the user agrees to give up that undo (the only choice for occurrences edited on their own, unchecked occurrences, or a series whose rule was shortened or whose first occurrence was deleted later). The undo of an update_reminder or delete_reminder is also refused, and its record kept, when the reminder list it restores into is not found under its recorded identifier; giving up the undo of a delete_reminder loses the deleted reminder. The undo of a delete_event, an update_event or a move of an event is refused the same way, its record kept, when the calendar it restores into is not found under its recorded identifier (judged after a Calendar access check and one re-read of the calendars, which can still show an older view); the error names the event, not the calendar or its account, and giving up the undo of a delete_event loses the deleted event. The undo of a delete_events_batch, delete_reminders_batch or cleanup_completed_reminders is refused before any write, its record kept whole, when the calendar or list of any of its items is missing or read-only (the error counts the items this stops and those whose calendar or list is in place); giving up that undo with discard_id drops every item of the entry. A batch undo that fails part-way keeps only the items not yet restored. A batch undo, whether it finishes or stops part-way, names the first five restored reminders whose store holds fields differently, with their fields, then says how many more. When the undo of a delete_reminder recreates the reminder and the store then holds some of its fields differently (a save that reported an error but was written), the message names those fields and asks to check the reminder. Five refusals discard the record instead, writing nothing: an update_event that touched a recurring event (one occurrence, span future or all, or rules added or removed), which undo never restores; an update_event or a move of a one-off event that repeats or is an edited occurrence by the time of the undo (revert either in Calendar if wanted; the calendar it restores into is read first, so when that calendar is missing the missing-calendar refusal comes first and the record is kept); a delete_event span future that did not start at the series' first occurrence and remove it all, or a delete_events_batch that holds such a delete (refused before any of its events is restored); and two for recurring reminder completions whose identifier now resolves to another occurrence. Undo of a delete of one occurrence restores it as a one-off event, not into its series; undo of a whole-series delete (delete_event span future from the first occurrence, or span all) recreates the series from its rules and then restores its exceptions inside the scan window (from one day before the first occurrence to the end of the rule, at most four years): an occurrence deleted on its own earlier stays deleted, one edited on its own comes back as a separate one-off event that no longer belongs to the series; the undo text says how many of each. Not restored as exceptions, and said in the text: a first occurrence edited or deleted on its own (kept from the rule, so its edit is lost or its deleted occurrence comes back), an edited occurrence moved more than a year outside the window (its slot counts as deleted), a series whose exceptions could not be listed, and a record that does not match the recreated series (none is applied); exceptions outside that window come back from the rules alone. If restoring them fails the recreated series and the one-off events are deleted again and the entry is kept for a retry; if that delete fails too, the error says so and the entry (in a batch, that member) is dropped. Undoing the earlier delete of an occurrence that the restored series already holds writes nothing and says so. Only works for operations in the current server session.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "discard_id": .object(["type": .string("string"), "description": .string("Explicitly discard only the current top undo record with this UUID from undo_history. Does not modify events/reminders or create redo history; cannot be reversed. Omit for normal undo.")])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "redo",
                description: "Redo the last undone operation. Only available after an undo. Only completions (complete_reminder) are written again. For any other record (a create, delete, update or move, or a batch of deletes) redo writes nothing, leaves the undo history unchanged, and answers success: false with the tool that repeats the operation; that entry is then removed from the redo history, and the next redo applies to whatever is then on top of it. Redo does not replay a create, delete, update or move by design: the tool that made it repeats it, with its own checks and its own undo entry. Redo of a completion refuses without writing anything when the reminder was changed after the undo; the redo entry is kept, except for a recurring reminder whose identifier now resolves to another occurrence, whose entry is discarded.",
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
                description: "List reminders from the Reminders app with optional filtering, sorting, and limiting. Includes has_recurrence, full public reminder_recurrence_rules (legacy alias recurrence_rules), due date precision, the start date (start, in the due shape; start_date/start_date_local) and time-based alarms (alarms: relative minutes_before, measured from the due date: positive = before the due date, negative = after; or absolute absolute_date; [] when none; location alarms stay in location_trigger). A date-only due (due.time null) is a day: is_overdue becomes true only once that day has ended in the host time zone, its due_date / due_date_local are 00:00 of the day in the host time zone, and a start stored as 00:00 without a time zone reads as a day in start (time null). Reports item_timezone (the reminder's own time zone; null when floating), where floating means the reminder stores no time zone; timezone is the host time zone, the zone of the *_local strings, not the reminder's.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "completed": .object(["type": .string("boolean"), "description": .string("Legacy filter: true=completed, false=incomplete, omit or JSON null=all. Must be a JSON boolean; strings and numbers are rejected even when 'filter' is supplied. Prefer using 'filter' parameter instead.")]),
                        "filter": .object([
                            "type": .string("string"),
                            "enum": .array([.string("all"), .string("incomplete"), .string("completed"), .string("overdue")]),
                            "description": .string("Filter reminders: 'all' (default), 'incomplete', 'completed', 'overdue' (incomplete with past due date; a date-only due only once its day has ended in the host time zone). Takes priority over 'completed' parameter.")
                        ]),
                        "sort": .object([
                            "type": .string("string"),
                            "enum": .array([.string("due_date"), .string("creation_date"), .string("priority"), .string("title")]),
                            "description": .string("Sort by: 'due_date' (default, nulls last; a date-only due sorts at the start of its day, before the timed dues of that day), 'creation_date', 'priority' (high→low), 'title' (alphabetical)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of reminders to return")
                        ]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional reminder list name")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "create_reminder",
                description: "Create a new reminder. A due_date given as a bare date (YYYY-MM-DD) makes a date-only reminder: a date with no time, as Reminders.app makes one; with a time it is a timed reminder in the host time zone. A create with a due date returns date_sync, as update_reminder does, with aligned judged on the saved reminder: for a bare date, false when the due reads back with a time or missing; for a time, false when the due reads back without its time or time zone even after it is written again around the start and saved a second time (as update_reminder does); for either, false when the reminder cannot be re-read. The duplicate check counts a bare date as 00:00 of that day, so a reminder with the same title at 00:00 of that day (how earlier versions stored a bare date) makes the call answer skipped, and its note says to use update_reminder with the bare date to make that one date-only. If the save reports an error but the reminder turns out to be saved, the call succeeds; when the store then holds some of its fields differently, the response's store_differs lists their keys, from `title`, `list`, `notes`, `priority`, `completion`, `url`, `start`, `due`, `due time zone`, `alarm count` and `recurrence rule count`, and note says to check the reminder and that creating it again with the same parameters may make a second copy.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string"), "description": .string("Reminder title")]),
                        "notes": .object(["type": .string("string"), "description": .string("Optional notes")]),
                        "due_date": .object(["type": .string("string"), "description": .string("Optional due date. A bare date (2026-01-30) makes a date-only reminder, with no time; for a time, ISO8601 with timezone (e.g., 2026-01-30T17:00:00+08:00)")]),
                        "priority": .object(["type": .string("integer"), "description": .string("Priority: 0=none, 1=high, 5=medium, 9=low")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Target reminder list name (use list_calendars with type='reminder' to see available options)")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Recurrence rule. Example: {\"frequency\": \"daily\"} for daily reminder. A key that is not one of this object's properties is refused and nothing is written, so a misspelled bound cannot leave the series open-ended."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1; an integer from 1 to 1000)")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). Giving occurrence_count too is refused.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences, an integer from 1 to 10000. Giving end_date too is refused.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday); used by every frequency")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days of month to repeat (1-31), for monthly and yearly rules; refused on daily and weekly rules, which do not use them")
                                ])
                            ]),
                            "required": .array([.string("frequency")])
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Tags for the reminder (stored as #hashtag text in notes, searchable via MCP). Example: [\"grocery\", \"urgent\"]")
                        ]),
                        "alarms_minutes_offsets": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                            "description": .string("Relative alarms, in minutes before the due date (positive = before, negative = after; integers from -525600 to 525600, one year). Writes only the relative alarms: absolute-date alarms and the location trigger are not changed. Needs a due_date with a time: refused without a due date (the alarm would never fire) and on a date-only reminder (when Reminders fires it there has not been measured), and nothing is created. On a recurring reminder EventKit is expected to move the alarm with each occurrence; that is not yet checked on a device. The response lists the relative alarms read back as alarms_minutes_offsets (minutes before); a skipped duplicate gets alarms_applied false; if the reminder cannot be re-read after the save, or store_differs lists alarm count, alarms_minutes_offsets is left out and alarms_read_back is false with alarms_read_back_note. \(ReminderRelativeAlarms.alarmNoteCondition) \(ReminderRelativeAlarms.alarmDisplayNote)")
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
                description: "Update an existing reminder. If the save fails at commit, the change may still be written by the next save this server makes, with no undo record of its own, and the error says so; reading the reminder back then does not rule it out. EventKit refusals 18, 23 and 26 left nothing behind and answer as a plain error. A failed second save of a due date (see date_sync) answers with aligned false and no error, and may land the same way. Changing due_date moves the start date and any absolute-date alarm by the same amount (in the rows measured, the Reminders.app list showed the earliest time-based alarm, relative or absolute); clear_due_date also clears the start date and removes absolute-date alarms. A due_date given as a bare date (YYYY-MM-DD) makes the reminder date-only instead, with no time: the start date is set to that day, also when it was set apart from the due date, and absolute-date alarms are removed, since Reminders.app would go on showing the earliest one's time; relative and location alarms are kept (if relative alarms remain, the response's alarms_note says so, see alarms_minutes_offsets); date_sync counts the removed alarms, and the response's note says how many and that undo restores them while this server is running, if the reminder has not been changed since. Giving the reminder's own date removes its time. realign_to_due instead puts them onto the due date, new or current, whatever it moved by: use it to repair a reminder whose alarm already disagrees with its due date. Relative and location alarms are unchanged; a moved alarm is written as a new alarm and keeps only its sound and email. The response's date_sync reports what moved and aligned: whether, on the saved reminder, the start date and the earliest absolute-date alarm agree with the due date. A start agrees on the due's day for a date-only due; for a timed due it agrees at the due instant, or on the due's day at midnight or without a time (that is how a date-only start is stored). An alarm set apart on purpose reads false, and so does a timed due that could only be saved without its time or zone, or a reminder that could not be read back after the save. Only updates that touch the due date (due_date, realign_to_due), the rule (recurrence, clear_recurrence) or the relative alarms (alarms_minutes_offsets) are read back after saving. The response's id is the reminder's identifier after the save; id_changed says whether it differs from reminder_id (a move to a list in another account may change it), and previous_id (only when it changed) repeats the reminder_id you passed. An update that makes the reminder date-only or undated while it keeps relative alarms adds alarms_note. recurrence replaces the reminder's recurrence rule and does not move the due date (recurrence_note says when the due is not on the rule's days), and clear_recurrence removes it; clear_due_date on a reminder that keeps repeating is refused (pass clear_recurrence with it).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminder_id": .object(["type": .string("string"), "description": .string("The reminder identifier")]),
                        "title": .object(["type": .string("string"), "description": .string("New title")]),
                        "notes": .object(["type": .string("string"), "description": .string("New notes")]),
                        "due_date": .object(["type": .string("string"), "description": .string("New due date. A bare date (2026-01-30) makes the reminder date-only (see the tool description); for a time, ISO8601 with timezone (e.g., 2026-01-30T17:00:00+08:00)")]),
                        "clear_due_date": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove due date from reminder Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
                        ]),
                        "realign_to_due": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to put the start date and absolute-date alarms onto the due date (due_date if given, otherwise the current one) instead of moving them by the change. Relative alarms stay, so an early relative alarm still sets what the Reminders.app list shows. The earliest absolute-date alarm lands on the due date and later ones keep their spacing after it, so with several alarms a stale one earlier than an intended early alarm pushes the early alarm past the due date; with a date-only due they move to its day and keep their time. A start that already agrees with the due date (any time on its day for a date-only due; the due instant, or its day at midnight or without a time, for a timed due) is left as it is; any other start is set to the due date. Cannot be combined with clear_due_date; fails when the reminder has no due date and none is given. With a bare-date due_date it changes nothing further: absolute-date alarms are removed. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
                        ]),
                        "priority": .object(["type": .string("integer"), "description": .string("New priority")]),
                        "calendar_name": .object(["type": .string("string"), "description": .string("Move reminder to a different list. A list in another account may give the reminder a new identifier: use the response's id (see id_changed).")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple lists share the same name.")]),
                        "alarms_minutes_offsets": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                            "description": .string("Replaces only the relative alarms, in minutes before the due date (positive = before, negative = after; integers from -525600 to 525600, one year); [] removes them. Absolute-date alarms and the location trigger are not changed (unlike update_event, whose list replaces all alarms). A non-empty list needs the reminder to have a due date with a time after the call: refused without one and on a date-only reminder (when Reminders fires it there has not been measured), and nothing is written. The response lists the relative alarms read back as alarms_minutes_offsets, with alarms_differ and alarms_note when they are not the ones asked for; if the reminder cannot be re-read after the save, alarms_minutes_offsets is left out and alarms_read_back is false with alarms_read_back_note. \(ReminderRelativeAlarms.alarmNoteCondition) \(ReminderRelativeAlarms.alarmDisplayNote) A call with due_date or realign_to_due and no alarms_minutes_offsets gets the same note on the same condition; a call that touches neither, such as a title change, gets none, and neither does a date-only reminder, so no note does not mean the list shows the due time. When a call without alarms_minutes_offsets changes the due date (due_date or clear_due_date) and the saved reminder is date-only or has no due date while it keeps relative alarms, they stay (nothing else is written) and alarms_note says how many are left, that they cannot fire as before (no due date, or a date-only one whose firing is not measured) and that alarms_minutes_offsets: [] removes them, unless the reminder could not be re-read after the save (date_sync.aligned false).")
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
                        ]),
                        "recurrence": .object([
                            "type": .string("object"),
                            "description": .string("Replaces the reminder's recurrence rule (same object as create_reminder's recurrence, without excluded_occurrence_dates); the identifier stays. It does not move the due date: when the due date is not on the new rule's days, the pending occurrence stays on it, and the response adds recurrence_note (after it is completed the reminder repeats on the rule's days: measured on iCloud for a weekly rule, expected for other rules); pass due_date to update_reminder to move it. days_of_week is used by every frequency and days_of_month by monthly and yearly. Needs a due date after the call (the request's or the stored one); refused on a completed reminder. The response reads back has_recurrence, reminder_recurrence_rules and due from the saved reminder after re-reading it (recurrence_read_back false, with recurrence_read_back_note, when it cannot be re-read). Cannot be combined with clear_recurrence. Undo restores the previous rule. A key that is not one of this object's properties is refused and nothing is written, so a misspelled bound cannot leave the series open-ended."),
                            "properties": .object([
                                "frequency": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")]),
                                    "description": .string("Recurrence frequency")
                                ]),
                                "interval": .object([
                                    "type": .string("integer"),
                                    "description": .string("Repeat every N units (default 1; an integer from 1 to 1000)")
                                ]),
                                "end_date": .object([
                                    "type": .string("string"),
                                    "description": .string("When to stop recurring (ISO8601 date). Giving occurrence_count too is refused.")
                                ]),
                                "occurrence_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("Maximum number of occurrences, an integer from 1 to 10000. Giving end_date too is refused.")
                                ]),
                                "days_of_week": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday); used by every frequency")
                                ]),
                                "days_of_month": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("integer")]),
                                    "description": .string("Days of month to repeat (1-31), for monthly and yearly rules; refused on daily and weekly rules, which do not use them")
                                ])
                            ]),
                            "required": .array([.string("frequency")])
                        ]),
                        "clear_recurrence": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove the reminder's recurrence rule, making it one-off; the due date stays. A repeating reminder must have a due date, so clear_due_date on a reminder that keeps repeating is refused: pass clear_recurrence with it to make the reminder one-off without a due date. Cannot be combined with recurrence. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
                        ]),
                        "clear_location_trigger": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove the reminder's location trigger. Cannot be combined with location_trigger (which replaces it): the pair is refused and nothing is written. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Replace existing tags with these new tags (stored as #hashtag text in notes). Example: [\"grocery\", \"urgent\"]")
                        ]),
                        "clear_tags": .object([
                            "type": .string("boolean"),
                            "description": .string("Set to true to remove all tags from the reminder. Cannot be combined with tags (which replaces them): the pair is refused and nothing is written. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
                        ])
                    ]),
                    "required": .array([.string("reminder_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "complete_reminder",
                description: "Mark a reminder as completed or incomplete. If the save fails at commit, the change may still be written by the next save this server makes, with no undo record of its own, and the error says so; reading the reminder back then does not rule it out. EventKit refusals 18, 23 and 26 left nothing behind and answer as a plain error. Read operation.status for write success; legacy is_completed is the saved object state. Recurring reminders may advance to another incomplete occurrence. next_occurrence reports confirmed or unknown; never retry completion just because the next occurrence is unknown. Annotated destructive: completing a recurring reminder advances the series irreversibly, and undo cannot restore a consumed occurrence once the identifier has rolled over. The hint is tool-wide, so clients that gate on it also prompt before reopening or completing a non-recurring reminder. After a confirmed rollover, next_occurrence.alarms_minutes_offsets lists the next occurrence's relative alarms (minutes before its due date), read after re-reading it (next_occurrence.alarms_read_back false with alarms_read_back_note when it cannot be re-read or changed in between); with any other next_occurrence.status these fields are absent. alarms_note names relative alarms that appeared on that read and were not there before the completion; one written by another app or a sync would look the same. This call sets only the completion fields, yet on iCloud the save that rolls over a repeating reminder with a location trigger leaves a 0-minute relative alarm on the next occurrence and on the completed copy; whether that alarm fires or shows in Reminders.app is not checked. The completed copy gets a new identifier and is not read.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminder_id": .object(["type": .string("string"), "description": .string("The reminder identifier")]),
                        "completed": .object(["type": .string("boolean"), "description": .string("true=completed, false=incomplete (omit or JSON null = true). Must be a JSON boolean; strings and numbers are rejected before any write.")])
                    ]),
                    "required": .array([.string("reminder_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "delete_reminder",
                description: "Delete a reminder. If the deletion fails, it may still happen with the next save this server makes, with no undo record of its own, and the error says so; reading the reminders back then does not rule it out.",
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
                description: "Search reminders by keyword(s) in title or notes, or filter by tag. Supports single keyword or multiple keywords with AND/OR matching. Includes has_recurrence, full public reminder_recurrence_rules (legacy alias recurrence_rules), due date precision, the start date (start, in the due shape; start_date/start_date_local) and time-based alarms (alarms: relative minutes_before, measured from the due date: positive = before the due date, negative = after; or absolute absolute_date; [] when none; location alarms stay in location_trigger). For a date-only due (due.time null), due_date / due_date_local are 00:00 of the day in the host time zone, and a start stored as 00:00 without a time zone reads as a day in start (time null). Reports item_timezone (the reminder's own time zone; null when floating), where floating means the reminder stores no time zone; timezone is the host time zone, the zone of the *_local strings, not the reminder's.",
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
                        "completed": .object(["type": .string("boolean"), "description": .string("Filter: true=completed, false=incomplete, omit or JSON null=all. Must be a JSON boolean; strings and numbers are rejected.")]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of reminders to return")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),

            // New Feature Tools

            // Feature 2: Search Events (enhanced with multi-keyword support)
            Tool(
                name: "search_events",
                description: "Search events by keyword(s) in title, notes, or location. Supports single keyword or multiple keywords with AND/OR matching. Without date range, defaults to ±2 years from today. Tip: To find past events beyond 2 years, always specify start_date. The response includes searched_range so you can verify coverage. The range is searched in full, in queries of at most four years each; a range longer than 146,000 days (about 400 years) is refused with an error. With only start_date or only end_date the other side stays two years from today, so such a range can be longer than 1462 days. Over a range longer than 1462 days, a read that passes about 200,000 event occurrences (about 2,000 a year over 100 years, all calendars read together; checked after each 1460-day part, which is read whole, before keywords are matched; limit does not lift it) stops with an error and returns nothing: narrow the range or give calendar_name. Over such a range, without limit at most 500 events are returned, with default_limit. truncated: true whenever fewer events are returned than event_count, a limit's cut included; event_count is still the total. Any such cut, on any range, keeps the events closest to today, sorted by start, and says so in truncation_note. Each event reports item_timezone (the event's own time zone; null when floating, all-day events included); timezone is the event's time zone, or the host time zone when the event is floating; the *_local strings are in display_timezone when given, otherwise in timezone. Outside detail_level summary each event lists its time-based alarms as alarms, the shape list_reminders uses (relative minutes_before, measured from the start: positive = before the start, negative = after; or absolute absolute_date, with absolute_date_local in the zone of the other *_local strings; [] when none; location alarms are not listed). An occurrence reports the series' alarms unless it was edited on its own.",
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
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of events to return, at most 10000: those closest to today, sorted by start. When omitted, all of them, except over a range longer than 1462 days: at most 500. A limit does not lift the read bound.")
                        ]),
                        "detail_level": .object([
                            "type": .string("string"),
                            "enum": .array([.string("summary"), .string("standard")]),
                            "description": .string("Response detail: 'summary' (id, title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day, calendar — plus location when set) or 'standard' (all fields, default). Use 'summary' to reduce token usage; pass an explicit 'fields' array for finer-grained selection.")
                        ]),
                        "display_timezone": .object([
                            "type": .string("string"),
                            "description": .string("IANA timezone (e.g., 'America/Los_Angeles') for *_local fields. If omitted, each event uses its own timezone.")
                        ]),
                        "fields": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Field names to include per event (e.g., ['title', 'start_date_local', 'calendar']). Overrides detail_level. 'id' always included. Available: title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day, calendar, location, notes, url, is_recurring, recurrence_rules, event_recurrence_rules, structured_location, attendees, organizer, alarms")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),

            // Feature 3: Quick Time Range
            Tool(
                name: "list_events_quick",
                description: "List events with quick time range shortcuts. Supports international week definitions. Each event reports item_timezone (the event's own time zone; null when floating, all-day events included); timezone is the event's time zone, or the host time zone when the event is floating; the *_local strings are in display_timezone when given, otherwise in timezone. Outside detail_level summary each event lists its time-based alarms as alarms, the shape list_reminders uses (relative minutes_before, measured from the start: positive = before the start, negative = after; or absolute absolute_date, with absolute_date_local in the zone of the other *_local strings; [] when none; location alarms are not listed). An occurrence reports the series' alarms unless it was edited on its own.",
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
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of events to return")
                        ]),
                        "detail_level": .object([
                            "type": .string("string"),
                            "enum": .array([.string("summary"), .string("standard")]),
                            "description": .string("Response detail: 'summary' (id, title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day, calendar — plus location when set) or 'standard' (all fields, default). Use 'summary' to reduce token usage; pass an explicit 'fields' array for finer-grained selection.")
                        ]),
                        "display_timezone": .object([
                            "type": .string("string"),
                            "description": .string("IANA timezone (e.g., 'America/Los_Angeles') for *_local fields. If omitted, each event uses its own timezone.")
                        ]),
                        "fields": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Field names to include per event (e.g., ['title', 'start_date_local', 'calendar']). Overrides detail_level. 'id' always included. Available: title, start_date, start_date_local, end_date, end_date_local, timezone, item_timezone, is_all_day, calendar, location, notes, url, is_recurring, recurrence_rules, event_recurrence_rules, structured_location, attendees, organizer, alarms")
                        ])
                    ]),
                    "required": .array([.string("range")])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
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
                                    "start_time": .object(["type": .string("string"), "description": .string("For an all-day event (all_day true) only the day counts, read in this Mac's time zone: send a date without an offset (a value with another offset is converted to this Mac's zone first, which can move it to another day; when it does, the result carries a warnings entry naming the field, its day in the written offset (written_day) and the day in this Mac's zone the request's dates are written with (host_day; a skipped duplicate writes nothing)).")]),
                                    "end_time": .object(["type": .string("string"), "description": .string("For an all-day event (all_day true) only the days count, read in this Mac's time zone: start_time names the first day; end_time is the day after the last day (exclusive, e.g. a one-night stay on 11-10 ends 11-11), the first day itself for a one-day event, or the last day at 23:59:59 as list_events returns it. Send all-day dates without an offset: a value with another offset is converted to this Mac's zone first, which can move it to another day. When it does, the event still uses this Mac's day and the result carries a warnings entry naming the field, its day in the written offset (written_day) and the day in this Mac's zone the request's dates are written with (host_day; a skipped duplicate writes nothing).")]),
                                    "notes": .object(["type": .string("string")]),
                                    "location": .object(["type": .string("string")]),
                                    "calendar_name": .object(["type": .string("string"), "description": .string("Target calendar name (required)")]),
                                    "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google')")]),
                                    "all_day": .object(["type": .string("boolean"), "description": .string("Whether this is an all-day event. Its dates are whole days, read in this Mac's time zone: see start_time and end_time. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")]),
                                    "recurrence": .object([
                                        "type": .string("object"),
                                        "description": .string("Recurrence rule. Any other key than these fails this item, so a misspelled bound cannot leave the series open-ended."),
                                        "properties": .object([
                                            "frequency": .object(["type": .string("string"), "enum": .array([.string("daily"), .string("weekly"), .string("monthly"), .string("yearly")])]),
                                            "interval": .object(["type": .string("integer"), "description": .string("Repeat every N units (default 1; an integer from 1 to 1000)")]),
                                            "end_date": .object(["type": .string("string")]),
                                            "occurrence_count": .object(["type": .string("integer"), "description": .string("Maximum number of occurrences, an integer from 1 to 10000. Giving end_date too fails this item. A yearly rule with days_of_week repeats in the start's month. With interval 1 and no days_of_month the rule refuses occurrence_count: use frequency monthly with interval 12 or end_date for those days, or yearly without days_of_week for once a year.")]),
                                            "days_of_week": .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string("Days to repeat (1=Sunday, 2=Monday, ..., 7=Saturday); the start has to fall on one of them")]),
                                            "days_of_month": .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string("Days of month to repeat (1-31), for monthly and yearly rules; refused on daily and weekly rules, which do not use them; the start has to fall on one of them")]),
                                            "excluded_occurrence_dates": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Occurrence dates to exclude at creation (max 100, occurrence_date grammar, best-effort all-or-nothing via compensating delete; first occurrence not excludable). Each date is the day the occurrence starts on: an occurrence that runs past midnight is removed by the day it starts, and a date it only runs into removes the occurrence starting on that day instead, or, when none starts on it, the create is rolled back with the no-occurrence error.")])
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
                description: "Check for overlapping events in a time range. The range is searched in full, in queries of at most four years each; a range longer than 146,000 days (about 400 years) is refused with an error. Over a range longer than 1462 days, a read that passes about 200,000 event occurrences (about 2,000 a year over 100 years, all calendars read together; checked after each 1460-day part, which is read whole) stops with an error and returns nothing: narrow the range, or give calendar_name, and other calendars are then not checked. Each event reports item_timezone (the event's own time zone; null when floating, all-day events included); timezone is the event's time zone, or the host time zone when the event is floating, the zone of the *_local strings. Each event lists its time-based alarms as alarms, the shape list_reminders uses (relative minutes_before, measured from the start: positive = before the start, negative = after; or absolute absolute_date, with absolute_date_local in the zone of the other *_local strings; [] when none; location alarms are not listed). An occurrence reports the series' alarms unless it was edited on its own.",
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
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),

            // Feature 6: Copy Event
            Tool(
                name: "copy_event",
                description: "Copy an event to another calendar. The copy is a new event with a new identifier; recurrence, attendees and the event's own structured location (its coordinates) are not copied. Availability (busy, free, tentative, unavailable) is copied when the target calendar supports the value; otherwise the copy gets the calendar's default. The result lists not_carried_over (structured_location, availability) when the copy did not keep them. Alarms are copied with their date or offset (when the event is a recurring series whose first occurrence was deleted, the copy is of its first remaining occurrence, and an alarm with an absolute date is put at that occurrence's start instead), location (coordinates and radius), email address and sound; a procedure alarm (one that opens a file or runs a script) becomes a plain alarm at the same time. If saving the copy fails while it carries location, email or sound alarms, which some calendars refuse, the error gives the failure code and names those alarm kinds (location_alarms, email_alarms, alarm_sounds) as a possible cause; the original is not removed. With delete_original true the event is moved instead, the same way as move_events_batch (in place first; new_id equals event_id unless id_changed is true; the result reports method, and not_carried_over when a fallback copy did not keep structured_location or availability (availability is kept when the target calendar supports the value): only those two keys are listed there, since a move that would drop recurrence or attendees is refused and a procedure alarm turned plain is not reported; a move to the event's own calendar writes nothing and reports action unchanged); recurring events are refused here, use move_events_batch with span and occurrence_dates. When a move falls back to copy and delete, undo restores the deleted original and then removes the copy; a copy changed since the move, given attendees, not found, recorded without an identifier, or not checkable is not removed, nor when its removal fails, and the answer says so. If deletion fails after a fallback copy, inspect the target calendar before retrying.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_id": .object(["type": .string("string"), "description": .string("The event identifier to copy")]),
                        "target_calendar": .object(["type": .string("string"), "description": .string("Target calendar name to copy to")]),
                        "target_calendar_source": .object(["type": .string("string"), "description": .string("Target calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "delete_original": .object(["type": .string("boolean"), "description": .string("If true, delete the original event after copying (effectively a move) Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")])
                    ]),
                    "required": .array([.string("event_id"), .string("target_calendar")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Feature 7: Move Events Batch
            Tool(
                name: "move_events_batch",
                description: "PREFERRED: Move multiple events to another calendar in a single call. Each event is moved in place (calendar reassigned), which keeps recurrence, attendees and every other field; the identifier stays the same within an account and changes when moving across accounts (the result's new_event_id). If an in-place move fails, the event is copied and the original removed, unless it has recurrence or attendees, in which case it is refused with a reason. For a recurring event, span 'this' (default) moves only the occurrence named in occurrence_dates, split out of the series; span 'all' moves the whole series (an occurrence date with span 'all' is refused). An event already in the target calendar is reported unchanged and nothing is written. Each result reports method (in_place / copied / split / unchanged), id_changed and any not_carried_over fields. not_carried_over lists only recurrence (a split occurrence becomes a one-off), absolute_alarms (a split occurrence's absolute-date alarms become alarms at its start), structured_location and availability (a copy keeps availability when the target calendar supports the value); a procedure alarm turned plain is not listed. If saving a copy fails while it carries location, email or sound alarms, which some calendars refuse, that event's error gives the failure code and names those alarm kinds as a possible cause; the original is not removed. Undo of an in-place move moves the event back; undo of a split or a fallback copy restores the original first and then removes the copy only when it is unchanged; a copy changed since the move, given attendees, not found, recorded without an identifier, or not checkable is not removed, nor when its removal fails; when an occurrence of a recurring event with the split occurrence's title already holds its time in the original calendar, nothing is recreated and the copy is not looked up or removed; the answer says which.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Array of event IDs to move")
                        ]),
                        "target_calendar": .object(["type": .string("string"), "description": .string("Target calendar name to move events to")]),
                        "target_calendar_source": .object(["type": .string("string"), "description": .string("Target calendar source (e.g., 'iCloud', 'Google'). Required when multiple calendars share the same name.")]),
                        "span": .object([
                            "type": .string("string"),
                            "enum": .array([.string("this"), .string("all")]),
                            "description": .string("For recurring events: 'this' (default) moves one occurrence (requires occurrence_dates); 'all' moves the whole series in place.")
                        ]),
                        "occurrence_dates": .object([
                            "type": .string("array"),
                            "items": .object(["type": .array([.string("string"), .string("null")])]),
                            "description": .string("Index-aligned with event_ids: the date of the occurrence to move for each recurring event with span 'this' (e.g., '2026-10-21' or '2026-10-21T10:00:00+08:00'): the day the occurrence starts on, in the event's time zone; null for the others. An occurrence that runs past midnight is found by the day it starts on; a date or time on the following day, even a time inside that occurrence, selects the occurrence starting on that following day, if any. Must have the same length as event_ids when given. A value that cannot be read fails the call; a value whose event lookup failed fails that row only.")
                        ])
                    ]),
                    "required": .array([.string("event_ids"), .string("target_calendar")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),

            // Feature 8: Delete Events Batch
            Tool(
                name: "delete_events_batch",
                description: "Delete multiple events. Two modes: (1) by event_ids - delete specific events, (2) by calendar + date range - delete all events matching criteria; with only before_date or only after_date the open side is searched 100 years out, and the response reports searched_from and searched_to; over a range wider than 1462 days, which every one-sided range is, more than 2000 deletions are refused, dry run included, and nothing is deleted, and the read itself stops with an error, nothing deleted, once it passes about 200,000 event occurrences (about 2,000 a year over 100 years, checked after each 1460-day part, which is read whole): give both after_date and before_date, at most 1460 days apart; span all and span future count each series once (an occurrence edited on its own that has its own id counts once more), and the dry run reports the count as deletions. Over such a range the dry-run preview lists at most 2000 events (preview_truncated). Span all deletes each listed series whole, and span future each listed series from the slot of its earliest listed occurrence to its end (an occurrence edited on its own is removed from its original slot, which can be before searched_from), both including occurrences outside searched_from / searched_to. By event_ids, span all through the identifier of an occurrence edited on its own would delete that occurrence only, so while another occurrence the call does not name remains that row is refused, in the dry run too, and the other rows go on (#416); when the series can be listed, the row says which id and span delete it. By event_ids with span all, a row with the series' own identifier, when its first occurrence was edited on its own and still starts at its original time, or was deleted with the first occurrence left edited on its own, and that occurrence starts no later than the next occurrence's slot or another occurrence's shown start, deletes the series from that occurrence with span 'future', as delete_event does (#436). That delete cannot be undone: the dry-run row gives occurrence_id and an undo_note; the real call lists it under through_first_occurrence with an undo_note and leaves it out of the call's undo, which restores the other rows, or, when no other row was deleted, is refused and dropped as delete_event's is. When that occurrence reports recurrence rules of its own (not measured), the row is refused. By date range the row is not delegated. By date range, an occurrence edited on its own that is the only listed occurrence of its series is deleted alone and the rest of the series stays (#427). With span future the response counts as already_removed the listed occurrences an earlier one removed with its series. Use dry_run=true (default) to preview before deleting. Preview returns only event_id + dates (no titles or calendar names) to avoid echoing untrusted content; pipe through list_events if you need full event details. Undo restores the batch's events, each as delete_event's undo would: a deleted occurrence of a recurring event comes back as a one-off event, and a series removed whole (span 'future' from its first occurrence, or span 'all') is recreated from its rules with its exceptions inside the scan window restored (an occurrence deleted on its own earlier stays deleted, one edited on its own comes back as a separate one-off event), and exceptions outside that window, a first occurrence edited or deleted on its own, a series that could not be listed and a record that does not match the recreated series come back from the rules alone, while an edited occurrence moved more than a year outside the window is not restored and its slot counts as deleted, which the undo text says (if restoring the exceptions and deleting the recreated series again both fail, that member is dropped from the batch); undoing the earlier delete of an occurrence that the restored series already holds writes nothing and says so. A batch holding a span 'future' delete that delete_event's undo would refuse is refused before any of its events is restored, and its history entry is discarded. The undo is also refused before any of its events is restored, and its history entry kept whole, when the calendar of any of its events is missing or read-only; giving up that undo with discard_id drops every event of the batch. If a restore still fails part-way, the entry keeps only the events not yet restored.",
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
                            "description": .string("Preview deletion without actually deleting (default: true). Set to false to execute deletion. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")
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
                description: "Find duplicate events across calendars. Useful before merging calendars to avoid duplicates. Matches by title (case-insensitive) and time (with configurable tolerance). Only events in different calendars are compared. A name that matches no calendar, or fewer than two calendars, is refused and nothing is returned; calendars_checked lists the calendars read, with the account where two share a title. Each side of a pair gives calendar and calendar_source. The range is searched in full, in queries of at most four years each; a range longer than 146,000 days (about 400 years) is refused with an error. Over a range longer than 1462 days, a read that passes about 200,000 event occurrences (about 2,000 a year over 100 years, all calendars read together; checked after each 1460-day part, which is read whole) stops with an error and returns nothing: narrow the range; naming fewer calendars in calendar_names, at least two, also reads less. Over such a range the search also stops with an error, returning nothing, once it passes 2,000,000 comparisons (a large tolerance_minutes over two calendars of one repeating event); narrow the range or the tolerance.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "calendar_names": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Calendar names to compare, matched as the other tools match them: the exact title, or ignoring case when no title matches exactly. A name two accounts share reads both; this tool has no calendar_source. Give titles from list_calendars, not a label from calendars_checked. If empty or omitted, compares ALL calendars, which must be at least two.")
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
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),

            // Reminder Batch Operations
            Tool(
                name: "create_reminders_batch",
                description: "PREFERRED: Create multiple reminders in a single call. Use this instead of calling create_reminder multiple times - it's faster and more reliable. Returns detailed results for each reminder; a result may carry store_differs and note, as create_reminder does, and creating that reminder again with the same parameters may make a second copy. A due_date given as a bare date (YYYY-MM-DD) makes a date-only reminder, as in create_reminder. A created row with a due date, bare or timed, carries date_sync, as create_reminder's result does.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reminders": .object([
                            "type": .string("array"),
                            "description": .string("Array of reminder objects to create. A key that is not one of a row's properties fails that row and nothing is written for it; recurrence and location_trigger are not accepted here, use create_reminder for those."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "title": .object(["type": .string("string")]),
                                    "notes": .object(["type": .string("string")]),
                                    "due_date": .object(["type": .string("string"), "description": .string("Due date: a bare date (2026-01-30) for a date-only reminder, or ISO8601 with timezone for a time")]),
                                    "priority": .object(["type": .string("integer"), "description": .string("Priority: 0=none, 1=high, 5=medium, 9=low")]),
                                    "calendar_name": .object(["type": .string("string"), "description": .string("Target reminder list name (required)")]),
                                    "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google')")]),
                                    "tags": .object([
                                        "type": .string("array"),
                                        "items": .object(["type": .string("string")]),
                                        "description": .string("Tags (stored as #hashtags)")
                                    ]),
                                    "alarms_minutes_offsets": .object([
                                        "type": .string("array"),
                                        "items": .object(["type": .string("integer")]),
                                        "description": .string("Relative alarms for this reminder, as create_reminder: minutes before the due date (integers from -525600 to 525600, one year), only the relative alarms, refused without a timed due date (date-only included) for that row; alarms_read_back as create_reminder. \(ReminderRelativeAlarms.alarmNoteCondition) \(ReminderRelativeAlarms.alarmDisplayNote)")
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
                description: "PREFERRED: Delete multiple reminders in a single call. When a row fails with a code, it may still be deleted by a later row or the next save this server makes: the response then adds failed_rows_note. Use this instead of calling delete_reminder multiple times - it's faster and more reliable. Returns detailed success/failure counts. The call is one undo entry: one undo recreates every reminder it deleted, one save at a time within that undo call, each under a new identifier and with what the undo snapshot records (not subtasks). The undo is refused before any reminder is recreated, and its history entry kept whole, when the list of any of its reminders is missing or read-only; giving up that undo with discard_id drops every reminder of the call. If a recreate still fails part-way, the entry keeps only the reminders not yet recreated.",
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
                        "include_completed": .object(["type": .string("boolean"), "description": .string("Include completed reminders (default: false, only scans incomplete) Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
            ),

            // Cleanup Tool
            Tool(
                name: "cleanup_completed_reminders",
                description: "Delete completed reminders in a single call. When a row fails with a code, it may still be deleted by the next save this server makes: the response then adds failed_rows_note. Intended for periodic cleanup (e.g. daily) without needing an external scheduler. \n\nBLAST RADIUS: without calendar_name, this affects every reminder list across every connected account (iCloud, Google, Exchange, local). Use dry_run=true (default) to preview scope before deleting. \n\nThe call is one undo entry, however many reminders it deleted, and it becomes the newest one: recording it clears the redo history, and only the newest 50 undo entries are kept, so a frequent scheduled cleanup pushes older entries out. One undo recreates every reminder it deleted (up to limit, or every reminder_ids entry), one save at a time within that undo call, each under a new identifier and with what the undo snapshot records (not subtasks). The undo is refused before any reminder is recreated, and its history entry kept whole, when the list of any of its reminders is missing or read-only; giving up that undo with discard_id drops every reminder of the call. If a recreate still fails part-way, the entry keeps only the reminders not yet recreated. \n\nPreview response returns only reminder_id (no titles) to avoid echoing untrusted content; pipe through list_reminders if you need full reminder details. \n\nTwo input modes: (1) FILTER — supply calendar_name/source (or neither) and the handler re-derives the reminder list on every call. Best for automations. (2) BINDING — supply reminder_ids and the handler acts on exactly those IDs. Best for interactive callers who read a preview and want the execute call to match it verbatim. When reminder_ids is supplied, filter parameters (calendar_name, calendar_source, limit) are ignored.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "calendar_name": .object(["type": .string("string"), "description": .string("Optional (filter mode): scope cleanup to this reminder list only. Omit to clean across all lists on all accounts. Ignored when reminder_ids is supplied.")]),
                        "calendar_source": .object(["type": .string("string"), "description": .string("Calendar source (e.g., 'iCloud', 'Google'). Only meaningful together with calendar_name — used to disambiguate when multiple calendars share the same name. calendar_source alone (without calendar_name) is rejected because EventKit cannot scope cleanup to 'any calendar from this source'.")]),
                        "dry_run": .object(["type": .string("boolean"), "description": .string("Preview deletion without actually deleting (default: true). Set to false to execute deletion. Must be a JSON boolean; strings and numbers are rejected. Omit or JSON null = default.")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum number of reminders to process in this call (default: 1000). If more completed reminders exist, the response includes remaining so callers know to re-invoke. Use to cap blast radius on large backlogs and to avoid multi-MB responses / long-running delete loops. Ignored when reminder_ids is supplied.")]),
                        "reminder_ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Optional (binding mode): exact list of reminder identifiers to delete. When supplied, filter parameters are ignored and the handler operates on this exact list. Any ID that is no longer completed, no longer exists, or fails to delete surfaces in the response failures[] array. Typical use: caller runs dry_run=true with filters, reads preview, then runs dry_run=false with reminder_ids taken from the preview to guarantee the execute call matches what was previewed.")
                        ])
                    ])
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
            let content = UntrustedContentWrapper.readTools.contains(name)
                ? UntrustedContentWrapper.wrap(result)
                : result
            return CallTool.Result(content: [.text(content)])
        } catch {
            // Outer catch (#37 spec R8). Per-batch handlers route their own
            // catches through writeFailureLog; this catch fires only when an
            // error escapes ALL inner handling — so a framework error here
            // means the operator's last debug channel is stderr. Delegates to
            // `writeFailureLog` (#72) so the #41 / R7 trusted-branch carve-out,
            // `escapeForStderr`, and any future hardening (#73 ANSI/NUL,
            // thread-safety) are inherited from a single site instead of
            // duplicated here.
            let code = EventKitErrorSanitizer.writeFailureLog(
                handler: "handleToolCall",
                identifier: name,
                error: error
            )
            return CallTool.Result(content: [.text("Error: \(code)")], isError: true)
        }
    }

    /// Test-only access to the private `handleToolCall` so #37 spec R8
    /// (outer-catch dispatch) can be pinned end-to-end. Production callers
    /// continue to invoke via the MCP `CallTool` handler registered in
    /// `start()`.
    func handleToolCallForTesting(name: String, arguments: [String: Value]) async -> CallTool.Result {
        await handleToolCall(name: name, arguments: arguments)
    }

    func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
        try ToolArgumentCheck.check(tool: name, arguments: arguments)
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
            return try await handleUndo(arguments: arguments)
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
        case "cleanup_completed_reminders":
            return try await handleCleanupCompletedReminders(arguments: arguments)

        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Calendar Handlers

    private func handleListCalendars(arguments: [String: Value]) async throws -> String {
        let entityType: EKEntityType?
        // PR #457 verify: any other string, `Reminder` included, used to list every calendar.
        switch arguments["type"]?.stringValue {
        case nil: entityType = nil
        case "event": entityType = .event
        case "reminder": entityType = .reminder
        default: throw ToolError.invalidParameter("type must be 'event' or 'reminder'")
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

        // #449: any other string used to make an event calendar.
        let entityType: EKEntityType
        switch typeStr {
        case "event": entityType = .event
        case "reminder": entityType = .reminder
        default: throw ToolError.invalidParameter("type must be 'event' or 'reminder'")
        }
        try InputValidation.validateCalendarTitle(title)
        let color = arguments["color"]?.stringValue

        let result = try await calendarWriteSource.writeNewCalendar(title: title, entityType: entityType, color: color)

        if result.isDuplicate {
            return try actionResult(["action": "skipped", "reason": "duplicate", "calendar": result.title, "id": result.identifier])
        }
        let fields: [String: Any] = ["action": "created", "calendar": result.title, "id": result.identifier]
        return try actionResult(fields.merging(NewObjectSave.responseFields(result.storeDiffers)) { $1 })
    }

    private func handleDeleteCalendar(arguments: [String: Value]) async throws -> String {
        guard let id = arguments["id"]?.stringValue else {
            throw ToolError.invalidParameter("id is required")
        }
        // #328 (PR #413 round 2): this switch guards an irreversible delete, so null must not fall
        // back to the unchecked delete. A misspelled key is refused at dispatch (#448).
        if case .null? = arguments["require_empty"] {
            throw ToolError.invalidParameter("require_empty must be true or false; null is not accepted here, since it would skip the emptiness check. Nothing was deleted.")
        }
        let requireEmpty = try InputValidation.requireOptionalBool(arguments, key: "require_empty") ?? false
        let checked = try await calendarDeletionSource.deleteCalendar(identifier: id, requireEmpty: requireEmpty)
        var result: [String: Any] = ["action": "deleted", "id": id]
        if let checked {
            // #328: what was searched, so "empty" never reads as empty outside the window.
            result["checked_empty"] = true
            if let searched = checked.searched {
                result["searched_from"] = EventRangeQuery.localText(searched.start)
                result["searched_to"] = EventRangeQuery.localText(searched.end)
            }
            if let reminders = checked.reminders { result["reminders_found"] = reminders }
        }
        return try actionResult(result)
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
        let limit = try InputValidation.requireOptionalLimit(arguments)
        let detailLevel = try InputValidation.validateDetailLevel(arguments)
        let displayTimezone = try InputValidation.parseDisplayTimezone(arguments)
        let fields = try InputValidation.parseFieldsFilter(arguments)

        var events = try await eventRangeReadSource.listEvents(
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

        // Apply limit. #332: over a wide range (`wideRangeDays`), no caller limit means at most
        // `EventRangeQuery.defaultWideOutput` rows. `truncated` says rows were left out, whoever
        // cut them; `default_limit` that the default did.
        let (rows, defaultLimit) = EventRangeQuery.bounded(events, requested: limit, searched: .init(start: startDate, end: endDate))

        let result = rows.map { formatEventDict($0, detailLevel: detailLevel, displayTimezone: displayTimezone, fields: fields) }

        var metadata: [String: Any] = [
            "total_in_range": totalInRange,
            "total_after_filter": totalAfterFilter,
            "filter": filterMode,
            "sort": sortMode
        ]
        if let limit = limit { metadata["limit"] = limit }
        if let defaultLimit { metadata["default_limit"] = defaultLimit }

        // #107: unified top-level <entity>_count semantic — pre-limit total
        // (taken from totalAfterFilter, before any prefix truncation).
        // Callers compute truncation via `event_count - len(events)` per
        // search_events existing pattern.
        var response: [String: Any] = [
            "event_count": totalAfterFilter,
            "events": result,
            "metadata": metadata
        ]
        if rows.count < totalAfterFilter { response["truncated"] = true }
        // F3 (#101): echo the raw user input ("UTC" stays "UTC") rather than
        // displayTimezone.identifier (Foundation normalizes UTC to GMT).
        if displayTimezone != nil,
           let raw = arguments["display_timezone"]?.stringValue {
            response["display_timezone"] = raw
        }
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
        let isAllDay = try InputValidation.requireOptionalBool(arguments, key: "all_day") ?? false
        try rejectAllDayTimezoneConflict(allDay: isAllDay, timezone: timezone)   // #190

        let alarmOffsets = try InputValidation.parseAlarmOffsets(arguments)   // #333: shared with the reminder tools

        let recurrenceRule = try parseRecurrenceRule(from: arguments, defaultTimezone: timezone, allowsExclusions: true)
        let structuredLocation = try parseStructuredLocation(from: arguments)

        let result = try await eventWriteSource.createEventValue(EventCreateRequest(
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
        ))

        // #182 — response contract: normalized excluded days + count. Present whenever
        // the request carried the field (including [] and idempotent skipped retries —
        // verify finding #12: created and skipped shapes stay congruent).
        var payload: [String: Any]
        if result.isDuplicate {
            payload = ["action": "skipped", "reason": "duplicate", "title": result.event.title ?? title, "id": result.event.eventIdentifier ?? "unknown"]
        } else {
            payload = ["action": "created", "title": result.event.title ?? title, "id": result.event.eventIdentifier ?? "unknown"]
        }
        if let excluded = recurrenceRule?.excludedOccurrenceDates {
            payload["excluded_occurrence_dates"] = excluded.map { EventKitManager.formatExclusionDay($0, timezone: timezone) }
            payload["exclusion_count"] = excluded.count
        }
        // #372: an all-day date whose written offset puts it on another day than this Mac's zone
        // (created and skipped alike).
        if isAllDay {
            let host = Calendar.gregorian(in: .current)
            payload.merge(AllDayOffsetWarning.responseFields(
                AllDayOffsetWarning.warnings(start: startDate, startText: startStr, end: endDate, endText: endStr, host: host),
                hostZone: host.timeZone, skipped: result.isDuplicate)) { $1 }
        }
        return try actionResult(payload)
    }

    private func handleUpdateEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }

        // Parse timezone first — naive datetimes (no offset) use this as default
        let timezone = try parseTimezone(from: arguments)

        let title = arguments["title"]?.stringValue
        let startText = arguments["start_time"]?.stringValue
        let endText = arguments["end_time"]?.stringValue
        let startDate: Date? = try startText.map { try parseFlexibleDate($0, defaultTimezone: timezone) }
        let endDate: Date? = try endText.map { try parseFlexibleDate($0, defaultTimezone: timezone) }
        let notes = arguments["notes"]?.stringValue
        let location = arguments["location"]?.stringValue
        let url = arguments["url"]?.stringValue
        try InputValidation.validateEventTextInput(title: title, notes: notes, location: location, url: url)

        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue
        let isAllDay = try InputValidation.requireOptionalBool(arguments, key: "all_day")
        try rejectAllDayTimezoneConflict(allDay: isAllDay ?? false, timezone: timezone)   // #190 — same-request pairing
        let spanStr = arguments["span"]?.stringValue ?? "this"
        let span: EKSpan
        switch spanStr {
        case "future": span = .futureEvents
        case "all": span = .futureEvents  // "all" on update = modify entire series from master
        default: span = .thisEvent
        }

        let alarmOffsets = try InputValidation.parseAlarmOffsets(arguments)   // #333: shared with the reminder tools

        let recurrenceRule = try parseRecurrenceRule(from: arguments, defaultTimezone: timezone)
        let clearRecurrence = try InputValidation.requireOptionalBool(arguments, key: "clear_recurrence") ?? false
        // PR #439 verify: clear_recurrence goes first in the manager, so the rule would be dropped.
        if recurrenceRule != nil && clearRecurrence {
            throw ToolError.invalidParameter(ReminderRecurrenceWrite.bothMessage)
        }
        let structuredLocation = try parseStructuredLocation(from: arguments)
        let clearTimezone = try InputValidation.requireOptionalBool(arguments, key: "clear_timezone") ?? false
        if clearTimezone && timezone != nil {
            throw ToolError.invalidParameter("Cannot specify both timezone and clear_timezone")
        }

        // #383: a value without offset is read in the event's current zone, the zone updateEvent's
        // findOccurrence takes the day boundary in, as delete_event and move_events_batch do (#270);
        // not in `timezone`, the zone the event gets after the update. Last, after every check that
        // needs no calendar (verify round 1): the lookup ensures calendar access and reads the store.
        let occurrenceDate: Date? = try await OccurrenceDateInput.resolve(
            arguments["occurrence_date"]?.stringValue, iso: dateFormatter, span: spanStr,
            zoneLookup: { try await self.eventWriteSource.occurrenceDateTimeZone(identifier: eventId) })

        let event = try await eventWriteSource.updateEventValue(EventUpdateRequest(
            identifier: eventId,
            fields: Set(arguments.filter { $0.value != .null }.keys),
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
        ))

        // #268: the identifier after the save (a move to another account's calendar changes it).
        var response: [String: Any] = ["action": "updated", "title": event.title ?? ""]
        response.merge(UpdatedIdentifier.responseFields(input: eventId, saved: event.eventIdentifier,
                                                        seriesIdentifier: event.seriesIdentifier)) { $1 }
        // #383 verify: the start of the occurrence occurrence_date matched, before the update.
        if let matched = event.matchedOccurrence {
            response["occurrence_start"] = OccurrenceStart.string(matched.start, zone: matched.zone)
        }
        // #372: only when the event is all-day after the update, and only for the fields the call
        // gave; the other end of the range is the saved event's.
        if event.isAllDay, startDate != nil || endDate != nil {
            let host = Calendar.gregorian(in: .current)
            response.merge(AllDayOffsetWarning.responseFields(
                AllDayOffsetWarning.warnings(start: startDate ?? event.startDate, startText: startText,
                                             end: endDate ?? event.endDate, endText: endText, host: host),
                hostZone: host.timeZone)) { $1 }
        }
        return try actionResult(response)
    }

    /// #428 verify r1: what `delete_event` span 'all' adds when it went through the series' first
    /// occurrence edited on its own (`SeriesDeleteRoute.firstEditedOccurrence`).
    static let seriesDeletedThroughOccurrenceNote = "The occurrence that comes first in this series was edited on its own, so the series was deleted from that occurrence (occurrence_id) with span 'future', which removes every occurrence. That delete cannot be undone: undo refuses it and drops its record."

    /// #436 (PR #465 verify r1): the batch's counterpart of `seriesDeletedThroughOccurrenceNote`.
    static let batchSeriesDeletedThroughOccurrenceNote = "The series in through_first_occurrence had their first occurrence edited on its own, so each was deleted from that occurrence (occurrence_id) with span 'future', which removes every occurrence. Those deletes cannot be undone and are left out of this call's undo, which restores only the other rows."

    /// PR #465 verify r2: the note when no other row was deleted, so the call has no undo of its own.
    static let batchOnlySeriesDeletedThroughOccurrenceNote = "The series in through_first_occurrence had their first occurrence edited on its own, so each was deleted from that occurrence (occurrence_id) with span 'future', which removes every occurrence. Those deletes cannot be undone, and no other row of this call was deleted: undo refuses this call's record and drops it, as for delete_event, and restores nothing."
    /// PR #465 verify r2: a dry-run row the real call deletes that way.
    static let batchPreviewThroughOccurrenceNote = "This row deletes the series from its first occurrence (occurrence_id), edited on its own, with span 'future'. That delete cannot be undone."

    private func handleDeleteEvent(arguments: [String: Value]) async throws -> String {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw ToolError.invalidParameter("event_id is required")
        }

        // A value without offset is read in the event's own zone, to match findOccurrence's day
        // boundary; the zone is read after access is ensured and from the refreshed event (#270,
        // #271). OccurrenceDateInput decides from the span and the value whether it is needed.
        let spanStr = arguments["span"]?.stringValue ?? "this"
        let occurrenceDate: Date? = try await OccurrenceDateInput.resolve(
            arguments["occurrence_date"]?.stringValue, iso: dateFormatter, span: spanStr,
            zoneLookup: { try await self.eventDeletionSource.occurrenceDateTimeZone(identifier: eventId) })

        if spanStr == "all" {
            var response: [String: Any] = ["action": "deleted", "id": eventId, "span": "all"]
            if case .firstEditedOccurrence(let occurrence) = try await eventDeletionSource.deleteEventSeries(identifier: eventId) {
                response["occurrence_id"] = occurrence
                response["undo_note"] = Self.seriesDeletedThroughOccurrenceNote
            }
            return try actionResult(response)
        }

        let span: EKSpan = spanStr == "future" ? .futureEvents : .thisEvent
        try await eventDeletionSource.deleteEvent(identifier: eventId, span: span, occurrenceDate: occurrenceDate)
        return try actionResult(["action": "deleted", "id": eventId, "span": spanStr])
    }

    // MARK: - Undo/Redo Handlers

    private func handleUndo(arguments: [String: Value]) async throws -> String {
        if let value = arguments["discard_id"] {
            guard let text = value.stringValue, let id = UUID(uuidString: text) else {
                throw ToolError.invalidParameter("discard_id must be a nonempty UUID string from undo_history")
            }
            let result = try await undoManager.discardUndo(expectedID: id)
            return try actionResult(["action": "discarded_undo", "success": true,
                                     "id": result.id, "description": result.description,
                                     "undo_available": result.undoCount, "redo_available": result.redoCount])
        }
        guard let record = try await undoManager.beginUndo() else {
            return try actionResult(["action": "undo", "success": false, "message": "Nothing to undo"])
        }
        // #191 — catch scope covers ONLY the execution (R2 fix): a response-
        // serialization failure after a SUCCESSFUL undo must not restore the
        // record (the operation really was undone). The active history record prevents
        // another undo/redo or explicit discard while execution is suspended.
        let message: String
        do {
            message = try await undoExecutionSource.executeUndo(record.operation)
        } catch let partial as UndoBatchPartiallyUndoneError {
            // #248 A: some members of a batch were restored before one failed. Put back only the
            // members not yet restored, under the same id, so a retry does not recreate the
            // restored ones a second time.
            // With nothing left (the last member dropped), the record is discarded instead.
            if partial.remaining.isEmpty {
                await undoManager.discardFailedUndo(record)
            } else {
                await undoManager.restoreFailedUndo(record, remaining: .batch(partial.remaining))
            }
            throw partial
        } catch {
            switch UndoFailureDisposition.of(error) {
            case .restore:
                // A failed undo must not consume the entry: put it back so the user
                // can fix the environment and retry (previously the record was lost
                // and a retry undid the WRONG, older operation).
                await undoManager.restoreFailedUndo(record)
            case .discard:
                // Permanent: re-appending would jam every older entry behind an
                // always-failing head (verify round 1 on PR #195, row 1).
                await undoManager.discardFailedUndo(record)
            }
            throw error
        }
        await undoManager.finishHistoryOperation(record)
        return try actionResult(["action": "undo", "success": true, "message": message])
    }

    /// #247: appended to the instruction of a redo entry that writes nothing, which `beginRedo` has
    /// just dropped, so a client does not call redo again expecting the same entry.
    static let droppedRedoNote = "This entry was removed from the redo history and cannot be redone. The next redo applies to whatever is now on top of the redo history, if anything: an older undone operation, which may itself be one that redo only answers like this; check redo_available before calling redo again."

    private func handleRedo() async throws -> String {
        let record: UndoRecord
        switch try await undoManager.beginRedo() {
        case .empty(let undoCount):
            return try actionResult(["action": "redo", "success": false, "message": "Nothing to redo",
                                     "undo_available": undoCount, "redo_available": 0])
        case .dropped(let top, let undoCount, let redoCount):
            // #247: nothing is executed and the undo stack did not move, so the next undo cannot
            // repeat the undo of this record (a deleted item recreated twice). The record left the
            // redo stack (maintainer decision, 2026-10-07), so its instruction is answered once and
            // the next redo applies to whatever is now on top of the redo stack (PR #282 round 2,
            // findings 7/11/15: that may be another record that is only answered).
            let instruction = top.operation.redoInstruction ?? "Nothing was written."
            return try actionResult(["action": "redo", "success": false,
                                     "message": instruction + " " + Self.droppedRedoNote,
                                     "undo_available": undoCount, "redo_available": redoCount])
        case .started(let started):
            record = started
        }
        // #191 — same catch-scope discipline as handleUndo (execution only).
        let message: String
        do {
            message = try await undoExecutionSource.executeRedo(record.operation)
        } catch {
            switch UndoFailureDisposition.of(error) {
            case .restore: await undoManager.restoreFailedRedo(record)
            case .discard: await undoManager.discardFailedRedo(record)
            }
            throw error
        }
        await undoManager.finishHistoryOperation(record)
        return try actionResult(["action": "redo", "success": true, "message": message])
    }

    private func handleUndoHistory(arguments: [String: Value]) async throws -> String {
        let limit = try InputValidation.requireOptionalLimit(arguments) ?? 10
        let snapshot = await undoManager.historySnapshot()
        let history = snapshot.entries
        let undoCount = snapshot.undoCount
        let redoCount = snapshot.redoCount

        let dateFormatter = DateFormatter.machineReadable("HH:mm:ss", zone: TimeZone.current)   // #304: ASCII digits

        let entries = history.prefix(limit).map { entry -> [String: Any] in
            [
                "index": entry.index,
                "id": entry.id,
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

    /// #231: start date and time-based alarms for list_reminders / search_reminders.
    /// `start` has the `due` shape; `start_date` / `start_date_local` mirror `due_date` / `due_date_local`.
    /// #297: under a date-only due, a 00:00 floating start reads as a day in `start`
    /// (`ReminderDueReading.startAsRead`); the strings keep their shape (host-zone midnight).
    /// #241: `item_timezone` is the reminder's own zone, null when floating; `timezone`
    /// stays the zone of the `*_local` strings (the host zone).
    private func reminderScheduleFields(_ reminder: ReminderReadSnapshot, zone: TimeZone = .current) -> [String: Any] {
        var fields: [String: Any] = [
            "item_timezone": reminder.timeZone?.identifier ?? NSNull(),
            // #297: under a date-only due, the 00:00 floating start the store hands back is a day.
            "start": ReminderDueValue(components: ReminderDueReading.startAsRead(reminder.startDateComponents,
                                                                                 due: reminder.dueDateComponents))?.dictionary ?? NSNull(),
            // Sorted and filtered here too, so the order holds however the snapshot was built.
            "alarms": AlarmReadOutput.dictionaries(reminder.alarms, absolute: { [dateFormatter] in dateFormatter.string(from: $0) },
                                                   absoluteLocal: { [localDateFormatter] in localDateFormatter.string(from: $0) })
        ]
        if let startDate = ReminderDueReading.displayInstant(reminder.startDateComponents, zone: zone) {
            fields["start_date"] = dateFormatter.string(from: startDate)
            fields["start_date_local"] = localDateFormatter.string(from: startDate)
        }
        return fields
    }

    private func handleListReminders(arguments: [String: Value]) async throws -> String {
        let filterMode = arguments["filter"]?.stringValue
        let sortMode = arguments["sort"]?.stringValue ?? "due_date"
        let limit = try InputValidation.requireOptionalLimit(arguments)
        // #29: enforce scope invariant consistent with cleanup_completed_reminders.
        // listReminders silently discards calendar_source when calendar_name is
        // nil — read-only so not destructive, but the API asymmetry is confusing
        // (users who learn from cleanup_completed_reminders that source-alone is
        // rejected reasonably expect the same here).
        let calendarName = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_name")
        let calendarSource = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_source")
        try ReminderCleanup.rejectSourceWithoutName(name: calendarName, source: calendarSource)

        // The type contract on `completed` is unconditional (BREAKING, see
        // CHANGELOG); validate it before deciding whether `filter` overrides it.
        let legacyCompleted = try InputValidation.requireOptionalBool(arguments, key: "completed")
        // Determine completion filter: 'filter' parameter takes priority over legacy 'completed'
        let completed: Bool?
        if let filterMode = filterMode {
            switch filterMode {
            case "completed": completed = true
            case "incomplete", "overdue": completed = false
            default: completed = nil  // "all"
            }
        } else {
            completed = legacyCompleted
        }

        let page = try await reminderReadSource.listReminderPage(
            completed: completed, calendarName: calendarName, calendarSource: calendarSource,
            query: ReminderPageQuery(overdueOnly: filterMode == "overdue", sort: sortMode, limit: limit))
        let now = page.referenceDate
        let reminders = page.reminders
        let totalFetched = page.totalFetched
        let totalAfterFilter = page.totalAfterFilter

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
            if let dueDate = ReminderDueReading.displayInstant(reminder.dueDateComponents, zone: page.zone) {
                dict["due_date"] = dateFormatter.string(from: dueDate)
                dict["due_date_local"] = localDateFormatter.string(from: dueDate)
                dict["is_overdue"] = !reminder.isCompleted
                    && ReminderDueReading.isOverdue(reminder.dueDateComponents, now: now, zone: page.zone) == true
            }
            if let completionDate = reminder.completionDate {
                dict["completion_date"] = dateFormatter.string(from: completionDate)
                dict["completion_date_local"] = localDateFormatter.string(from: completionDate)
            }
            if let creationDate = reminder.creationDate {
                dict["creation_date"] = dateFormatter.string(from: creationDate)
                dict["creation_date_local"] = localDateFormatter.string(from: creationDate)
            }
            if let trigger = reminder.locationTrigger { dict["location_trigger"] = trigger.dictionary }
            dict.merge(reminderScheduleFields(reminder, zone: page.zone)) { _, new in new }
            dict.merge(reminder.recurrenceMetadata) { _, new in new }
            return dict
        }

        var metadata: [String: Any] = [
            "total_fetched": totalFetched,
            "total_after_filter": totalAfterFilter,
            "filter": filterMode ?? "all",
            "sort": sortMode
        ]
        if let limit = limit { metadata["limit"] = limit }

        // #107: unified top-level <entity>_count semantic — pre-limit total.
        let response: [String: Any] = [
            "reminder_count": totalAfterFilter,
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

        let due = try arguments["due_date"]?.stringValue.map { try parseReminderDue($0) }
        let priority = try InputValidation.requireIntIfPresent(arguments, key: "priority", default: 0)
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let recurrenceRule = try parseRecurrenceRule(from: arguments, forReminder: true)
        let locationTrigger = try parseLocationTrigger(from: arguments)
        // #333: refused before the store is called when the alarm could not fire as asked.
        let alarmOffsets = try InputValidation.parseAlarmOffsets(arguments)
        try ReminderRelativeAlarms.check(alarmOffsets, due: ReminderRelativeAlarms.dueState(requested: due, clearDue: false, existing: nil))

        let result = try await reminderWriteSource.createReminder(ReminderCreateRequest(
            title: title,
            notes: notes,
            due: due,
            priority: priority,
            calendarName: calendarName,
            calendarSource: calendarSource,
            recurrenceRule: recurrenceRule,
            locationTrigger: locationTrigger,
            alarmOffsets: alarmOffsets
        ))

        if result.isDuplicate {
            var skipped: [String: Any] = ["action": "skipped", "reason": "duplicate", "title": result.reminder.title ?? title, "id": result.reminder.calendarItemIdentifier]
            if let note = Self.dateOnlyDuplicateNote(due: due, result: result) { skipped["note"] = note }
            skipped.merge(Self.alarmResponseFields(requested: alarmOffsets, result: result)) { $1 }
            return try actionResult(skipped)
        }
        var fields: [String: Any] = ["action": "created", "title": result.reminder.title ?? title, "id": result.reminder.calendarItemIdentifier]
        if !tags.isEmpty {
            fields["tags"] = tags
        }
        // #301 / #308: a dated create (date-only or timed) says whether the saved reminder reads
        // back as asked.
        if let dateSync = result.dateSync { fields["date_sync"] = dateSync.dictionary }
        fields.merge(NewObjectSave.responseFields(result.storeDiffers)) { $1 }
        fields.merge(Self.alarmResponseFields(requested: alarmOffsets, result: result)) { $1 }
        return try actionResult(fields)
    }

    /// #333: a skipped duplicate writes no alarm, and says so.
    static let duplicateAlarmsNote = "alarms_minutes_offsets was not applied: a reminder with this title and due date already exists and was left as it is. To set its alarms, call update_reminder with its id."

    /// #333: the relative alarms read back after a create (`alarms_minutes_offsets`, minutes
    /// before), with `alarms_differ` and a note when they are not the ones asked for; for a skipped
    /// duplicate, `alarms_applied` false and the note. Empty when the call asked for none.
    static func alarmResponseFields(requested: [Int]?, result: EventKitManager.CreateReminderResult) -> [String: Any] {
        guard let requested else { return [:] }
        if result.isDuplicate { return ["alarms_applied": false, "alarms_note": duplicateAlarmsNote] }
        return storedAlarmFields(requested: requested, stored: result.storedRelativeAlarms, listShowsAlarmTime: result.listShowsAlarmTime)
    }

    /// PR #438 verify: `alarms_read_back` as `complete_reminder` reports it on `next_occurrence`.
    static let alarmsUnreadNote = "The reminder's relative alarms are not confirmed: it could not be re-read after the save, or the alarm count in the store is not the one written. Check them with list_reminders."

    static func storedAlarmFields(requested: [Int], stored: [Double]?, listShowsAlarmTime: Bool) -> [String: Any] {
        guard let stored else { return ["alarms_read_back": false, "alarms_read_back_note": alarmsUnreadNote] }
        var fields: [String: Any] = ["alarms_minutes_offsets": stored]
        var notes: [String] = []
        if ReminderRelativeAlarms.differs(requested: requested, stored: stored) {
            fields["alarms_differ"] = true
            notes.append("The reminder holds different relative alarms than requested; check it in Reminders.")
        }
        if listShowsAlarmTime { notes.append(ReminderRelativeAlarms.alarmDisplayNote) }   // #433
        if !notes.isEmpty { fields["alarms_note"] = notes.joined(separator: " ") }
        return fields
    }

    /// `alarms_note` can hold more than one note; none replaces another.
    static func appendAlarmNote(_ note: String, to fields: inout [String: Any]) {
        fields["alarms_note"] = (fields["alarms_note"] as? String).map { "\($0) \(note)" } ?? note
    }

    private func handleUpdateReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }

        let title = arguments["title"]?.stringValue
        let userNotes = arguments["notes"]?.stringValue
        try InputValidation.validateReminderTextInput(title: title, notes: userNotes)

        let newTags = arguments["tags"]?.arrayValue?.compactMap { $0.stringValue }
        let clearTags = try InputValidation.requireOptionalBool(arguments, key: "clear_tags") ?? false
        // #486: the clear used to win and the tags were dropped with a success answer.
        if newTags != nil && clearTags {
            throw ToolError.invalidParameter(ReminderUpdateWrite.tagsBothMessage)
        }
        let due = try arguments["due_date"]?.stringValue.map { try parseReminderDue($0) }
        let clearDueDate = try InputValidation.requireOptionalBool(arguments, key: "clear_due_date") ?? false
        if clearDueDate && due != nil {
            throw ToolError.invalidParameter("Cannot specify both due_date and clear_due_date")
        }
        let realignToDue = try InputValidation.requireOptionalBool(arguments, key: "realign_to_due") ?? false
        if realignToDue && clearDueDate {
            throw ToolError.invalidParameter("Cannot specify both realign_to_due and clear_due_date")
        }
        let priority = try InputValidation.requireOptionalIntOrNull(arguments, key: "priority")
        let calendarName = arguments["calendar_name"]?.stringValue
        let calendarSource = arguments["calendar_source"]?.stringValue

        let locationTrigger = try parseLocationTrigger(from: arguments)
        let clearLocationTrigger = try InputValidation.requireOptionalBool(arguments, key: "clear_location_trigger") ?? false
        // #486: the clear used to win and the trigger was dropped with a success answer.
        if locationTrigger != nil && clearLocationTrigger {
            throw ToolError.invalidParameter(ReminderUpdateWrite.locationTriggerBothMessage)
        }
        // #333: what the request alone settles is refused here (a bare-date due or clear_due_date
        // with alarms); the stored due is checked by the store before any write.
        // #354: the rule; both together, or a rule with clear_due_date, are refused here.
        let recurrenceRule = try parseRecurrenceRule(from: arguments, forReminder: true)
        let clearRecurrence = try InputValidation.requireOptionalBool(arguments, key: "clear_recurrence") ?? false
        if recurrenceRule != nil && clearRecurrence {
            throw ToolError.invalidParameter(ReminderRecurrenceWrite.bothMessage)
        }
        if recurrenceRule != nil && clearDueDate {
            throw ToolError.invalidParameter(ReminderRecurrenceWrite.clearDueWithRuleMessage)
        }
        let alarmOffsets = try InputValidation.parseAlarmOffsets(arguments)
        if due != nil || clearDueDate {
            try ReminderRelativeAlarms.check(alarmOffsets, due: ReminderRelativeAlarms.dueState(requested: due, clearDue: clearDueDate, existing: nil))
        }

        // Determine final notes:
        // If user provides notes, use their notes as the base (replacing existing notes content)
        // If user provides tags or clear_tags, merge tags with existing or new notes
        var finalNotes: String? = nil
        let hasNotesChange = userNotes != nil
        let hasTagChange = newTags != nil || clearTags

        if hasNotesChange || hasTagChange {
            // Need to read existing reminder to get current notes for tag merging
            let existingReminder = try await reminderWriteSource.getReminder(identifier: reminderId)
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

        let update = try await reminderWriteSource.updateReminder(ReminderUpdateRequest(
            identifier: reminderId,
            title: title,
            notes: finalNotes,
            due: due,
            priority: priority,
            calendarName: calendarName,
            calendarSource: calendarSource,
            locationTrigger: locationTrigger,
            clearLocationTrigger: clearLocationTrigger,
            clearDueDate: clearDueDate,
            realignToDue: realignToDue,
            alarmOffsets: alarmOffsets,
            recurrenceRule: recurrenceRule,
            clearRecurrence: clearRecurrence
        ))

        var response: [String: Any] = ["action": "updated", "title": update.reminder.title ?? ""]
        if let alarmOffsets {
            response.merge(Self.storedAlarmFields(requested: alarmOffsets, stored: update.storedRelativeAlarms,
                                                  listShowsAlarmTime: update.listShowsAlarmTime)) { $1 }
        }
        if let leftover = update.leftoverAlarmsNote { Self.appendAlarmNote(leftover, to: &response) }   // PR #415 verify round 1
        // PR #438 verify: a due change on a reminder that keeps its alarms is what #433 explains.
        if alarmOffsets == nil, update.listShowsAlarmTime { Self.appendAlarmNote(ReminderRelativeAlarms.alarmDisplayNote, to: &response) }
        // #354: the rule and the due read back off the saved reminder; a note when the due is off the rule's days.
        if let recurrence = update.recurrence {
            if recurrence.confirmed {
                response.merge(reminderMetadata(hasRecurrence: recurrence.hasRecurrence, rules: recurrence.rules, due: recurrence.due)) { $1 }
                if let note = recurrence.offRuleNote { response["recurrence_note"] = note }
            } else {
                // PR #420 verify round 1: not re-read after the save, so nothing is reported as stored.
                response["recurrence_read_back"] = false
                response["recurrence_read_back_note"] = ReminderRecurrenceWrite.unconfirmedNote   // round 2: its own key
            }
        }
        // #268: the identifier after the save (a move to another account's list may change it).
        response.merge(UpdatedIdentifier.responseFields(input: reminderId, saved: update.reminder.calendarItemIdentifier)) { $1 }
        // #227: what moved with the due date (start date, absolute-date alarms); #235: whether
        // they agree with it, also for a call with only realign_to_due.
        if let sync = update.dateSync { response["date_sync"] = sync.dictionary }
        if case .day? = due, let removed = update.dateSync?.absoluteAlarmsRemoved, removed > 0 {
            response["note"] = Self.dateOnlyAlarmRemovalNote(removed)
        }
        return try actionResult(response)
    }

    /// #267 (PR #298 verify round 2): a date-only update that removed absolute-date alarms says so
    /// in words, and how to get them back (the undo history lives in this process).
    static func dateOnlyAlarmRemovalNote(_ removed: Int) -> String {
        "Made date-only: removed \(removed) absolute-date alarm\(removed == 1 ? "" : "s"), because Reminders.app would go on showing an alarm's time. undo restores \(removed == 1 ? "it" : "them") while this server is running, if the reminder has not been changed since."
    }

    /// #267 (PR #298 verify round 2): a bare-date create skipped as a duplicate of a reminder with a
    /// time (what a bare date was stored as before #267) says the existing one was left as it is.
    static func dateOnlyDuplicateNote(due: ReminderDueInput?, result: EventKitManager.CreateReminderResult) -> String? {
        guard case .day? = due, result.isDuplicate, result.duplicateHasTime else { return nil }
        return "The existing reminder with this title has a time on that day and was left as it is. To make it date-only, call update_reminder with this bare date."
    }

    private func handleCompleteReminder(arguments: [String: Value]) async throws -> String {
        guard let reminderId = arguments["reminder_id"]?.stringValue else {
            throw ToolError.invalidParameter("reminder_id is required")
        }
        // BREAKING (see CHANGELOG): a non-boolean `completed` is rejected before
        // any write. Omitted or JSON null still means complete.
        let completed = try InputValidation.requireOptionalBool(arguments, key: "completed") ?? true
        let result = try await reminderCompletionSource.completeReminder(identifier: reminderId, completed: completed)
        return try actionResult(result.dictionary)
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

        if let title { try InputValidation.validateCalendarTitle(title) }

        let calendar = try await calendarWriteSource.writeCalendarUpdate(identifier: id, title: title, color: color)

        return try actionResult(["action": "updated", "calendar": calendar.title, "id": calendar.identifier])
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
        // #29 extension: handleSearchReminders had the same silent-widen bug
        // as handleListReminders / handleListReminderTags — searchReminders
        // primitive only resolves calendars when calendarName is non-nil, so
        // calendar_source alone was silently widening the search to all lists.
        // Apply the same ReminderCleanup guards for API consistency.
        let calendarName = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_name")
        let calendarSource = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_source")
        try ReminderCleanup.rejectSourceWithoutName(name: calendarName, source: calendarSource)
        let completed = try InputValidation.requireOptionalBool(arguments, key: "completed")
        // #107 B1: add limit parameter to align search_reminders with search_events.
        // Uses requireOptionalLimit (cap=10000) — same defense-in-depth as search_events.
        let limit = try InputValidation.requireOptionalLimit(arguments)

        let page = try await reminderReadSource.searchReminderPage(
            keywords: keywords, matchMode: matchMode, calendarName: calendarName,
            calendarSource: calendarSource, completed: completed,
            query: ReminderPageQuery(tag: tagFilter, limit: limit))
        let reminders = page.reminders
        let totalCount = page.totalAfterFilter

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
            if let dueDate = ReminderDueReading.displayInstant(reminder.dueDateComponents, zone: .current) {
                dict["due_date"] = dateFormatter.string(from: dueDate)
                dict["due_date_local"] = localDateFormatter.string(from: dueDate)
            }
            if let completionDate = reminder.completionDate {
                dict["completion_date"] = dateFormatter.string(from: completionDate)
                dict["completion_date_local"] = localDateFormatter.string(from: completionDate)
            }
            if let trigger = reminder.locationTrigger { dict["location_trigger"] = trigger.dictionary }
            dict.merge(reminderScheduleFields(reminder)) { _, new in new }
            dict.merge(reminder.recurrenceMetadata) { _, new in new }
            return dict
        }

        var response: [String: Any] = [
            "match_mode": matchMode,
            "reminder_count": totalCount,
            "reminders": result
        ]
        if !keywords.isEmpty { response["keywords"] = keywords }
        if let tagFilter = tagFilter { response["tag_filter"] = tagFilter }
        // #107: echo back limit when caller specified one (mirror search_events L2211).
        if let limit = limit { response["limit"] = limit }
        return try formatJSON(response)
    }

    /// #441: the keys a `create_reminders_batch` row may have; the handler reads exactly these and
    /// refuses a row with any other.
    static let reminderBatchRowKeys = ["title", "notes", "due_date", "priority", "calendar_name", "calendar_source", "tags", "alarms_minutes_offsets"]

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

            // #441: a key that is not read is dropped, so `recurrence` made a one-off reminder and a
            // misspelled `due_date` one with no due date. Checked first, so a misspelled `title` is
            // named as a key. The key is not echoed (#37).
            guard Set(reminderDict.keys).isSubset(of: Self.reminderBatchRowKeys) else {
                let keys = Self.reminderBatchRowKeys
                let message = "Row \(index) accepts only \(keys.dropLast().joined(separator: ", ")) and \(keys[keys.count - 1]); another key was given. For recurrence or location_trigger, use create_reminder. Nothing was written for this row."
                results.append(["index": index, "success": false, "error": message])
                continue
            }

            // #448: a numeric due_date or a bare-string tags read as absent.
            if let problem = ToolArgumentCheck.rowProblem(tool: "create_reminders_batch", rowsKey: "reminders", row: reminderDict, index: index, checksKeys: false) {
                results.append(["index": index, "success": false, "error": problem])
                continue
            }

            guard let title = reminderDict["title"]?.stringValue else {
                results.append(["index": index, "success": false, "error": "title is required"])
                continue
            }

            do {
                let batchUserNotes = reminderDict["notes"]?.stringValue
                try InputValidation.validateReminderTextInput(title: title, notes: batchUserNotes)

                let batchDue = try reminderDict["due_date"]?.stringValue.map { try parseReminderDue($0) }
                let batchTags = reminderDict["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let batchNotes = buildNotesWithTags(notes: batchUserNotes, tags: batchTags)
                // #333: per row, refused for that row only.
                let batchAlarms = try InputValidation.parseAlarmOffsets(reminderDict)
                try ReminderRelativeAlarms.check(batchAlarms, due: ReminderRelativeAlarms.dueState(requested: batchDue, clearDue: false, existing: nil))
                let result = try await reminderWriteSource.createReminder(ReminderCreateRequest(
                    title: title,
                    notes: batchNotes,
                    due: batchDue,
                    priority: try InputValidation.requireIntIfPresent(reminderDict, key: "priority", default: 0),
                    calendarName: reminderDict["calendar_name"]?.stringValue,
                    calendarSource: reminderDict["calendar_source"]?.stringValue,
                    alarmOffsets: batchAlarms
                ))
                var entry: [String: Any] = [
                    "index": index,
                    "success": true,
                    "reminder_id": result.reminder.calendarItemIdentifier,
                    "title": result.reminder.title ?? title
                ]
                if result.isDuplicate {
                    entry["skipped"] = true
                    if let note = Self.dateOnlyDuplicateNote(due: batchDue, result: result) { entry["note"] = note }
                } else if let dateSync = result.dateSync {
                    entry["date_sync"] = dateSync.dictionary   // #301 / #308: a dated create
                }
                entry.merge(NewObjectSave.responseFields(result.storeDiffers)) { $1 }
                entry.merge(Self.alarmResponseFields(requested: batchAlarms, result: result)) { $1 }
                results.append(entry)
            } catch {
                results.append([
                    "index": index,
                    "success": false,
                    "error": EventKitErrorSanitizer.writeFailureLog(
                        handler: "createRemindersBatch",
                        identifier: "\(index)",
                        error: error
                    )
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

        let result = try await reminderCleanupSource.deleteRemindersBatch(identifiers: reminderIds, onlyCompleted: false)

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
        response.merge(result.failedRowsNoteField) { $1 }   // #274

        return try formatJSON(response)
    }

    // MARK: - Tag Handlers

    private func handleListReminderTags(arguments: [String: Value]) async throws -> String {
        // #29: same scope-invariant enforcement as handleListReminders — see there for rationale.
        let calendarName = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_name")
        let calendarSource = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_source")
        try ReminderCleanup.rejectSourceWithoutName(name: calendarName, source: calendarSource)
        let includeCompleted = try InputValidation.requireOptionalBool(arguments, key: "include_completed") ?? false

        let completed: Bool? = includeCompleted ? nil : false

        // #203: through the read seam, like list_reminders / search_reminders —
        // value copies made inside the manager actor; no raw EKReminder escapes.
        let reminders = try await reminderReadSource.listReminderSnapshots(
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

    private func handleCleanupCompletedReminders(arguments: [String: Value]) async throws -> String {
        let dryRun = try InputValidation.requireOptionalBool(arguments, key: "dry_run") ?? true

        // #28 binding mode: caller supplied exact reminder_ids. Skip the
        // list/dedupe/slice pipeline entirely — we act on the caller's list
        // verbatim (still deduped for math-consistency with R2-F2). Filter
        // parameters are ignored in this mode per tool description.
        let uniqueIdentifiers: [String]
        let total: Int
        let limit: Int
        let mode: String
        if let raw = arguments["reminder_ids"] {
            guard let array = raw.arrayValue else {
                throw ToolError.invalidParameter("reminder_ids must be an array of strings")
            }
            var seen = Set<String>()
            var parsed: [String] = []
            for (idx, v) in array.enumerated() {
                guard let s = v.stringValue else {
                    throw ToolError.invalidParameter("reminder_ids[\(idx)] must be a string")
                }
                guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolError.invalidParameter("reminder_ids[\(idx)] must not be empty")
                }
                if seen.insert(s).inserted { parsed.append(s) }
            }
            uniqueIdentifiers = parsed
            total = parsed.count
            limit = parsed.count
            mode = "binding"
        } else {
            // Filter mode — original flow.
            //
            // R2-F1: parse filter keys with strict type checking BEFORE any
            // other work. `Value.stringValue` returns nil for non-.string
            // cases, so a naive `.stringValue` coercion on
            // `{"calendar_source": 123}` would silently set calendarSource=nil
            // and slip past the F1 guard — widening a destructive tool to all
            // accounts. Reject malformed types at the boundary.
            let calendarName = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_name")
            let calendarSource = try ReminderCleanup.requireStringIfPresent(arguments, key: "calendar_source")
            let parsedLimit = try InputValidation.requireIntIfPresent(arguments, key: "limit", default: 1000)

            // F1: reject calendar_source without (non-empty) calendar_name.
            // R2-F3 strengthened this to reject empty/whitespace names.
            try ReminderCleanup.rejectSourceWithoutName(name: calendarName, source: calendarSource)
            guard parsedLimit > 0 else {
                throw ToolError.invalidParameter("limit must be greater than zero")
            }

            // #31: dispatched through the injected `reminderCleanupSource`
            // (protocol-typed) rather than `eventKitManager` (concrete)
            // so tests can substitute a fake. `listCompletedReminderIdentifiers`
            // projects [EKReminder] → [String] so the fake doesn't have to
            // fabricate EKReminder instances.
            let completedIdentifiers = try await reminderCleanupSource.listCompletedReminderIdentifiers(
                calendarName: calendarName,
                calendarSource: calendarSource
            )

            // F2 dedupe.
            uniqueIdentifiers = Array(Set(completedIdentifiers))
            total = uniqueIdentifiers.count
            limit = parsedLimit
            mode = "filter"
        }

        // F4 limit cap. Order is non-deterministic after Set round-trip —
        // intentional for filter mode (caller re-invokes to drain). In
        // binding mode limit == total so prefix is a no-op.
        let identifiers = Array(uniqueIdentifiers.prefix(limit))
        let remaining = max(0, uniqueIdentifiers.count - identifiers.count)

        if dryRun {
            // F3: only return reminder_id. Titles and calendar names are
            // attacker-controllable and handler is excluded from
            // UntrustedContentWrapper.readTools. Callers needing titles pipe
            // through list_reminders (wrapped).
            let preview: [[String: Any]] = identifiers.map { ["reminder_id": $0] }
            var response: [String: Any] = [
                "dry_run": true,
                "mode": mode,
                "total": total,
                "reminders_to_delete": preview,
                "remaining": remaining,
                "message": total == 0
                    ? (mode == "binding" ? "reminder_ids was empty." : "No completed reminders match the filter.")
                    : (remaining > 0
                        ? "Previewing first \(identifiers.count) of \(total). Re-invoke to see the rest, or set dry_run=false to delete this batch."
                        : (mode == "binding"
                            ? "Set dry_run=false to delete these \(total) reminders."
                            : "Set dry_run=false to execute deletion."))
            ]
            response["deleted_count"] = 0
            response["deleted_ids"] = [] as [String]
            response["failures"] = [] as [[String: String]]
            return try formatJSON(response)
        }

        if identifiers.isEmpty {
            let response: [String: Any] = [
                "dry_run": false,
                "mode": mode,
                "total": 0,
                "deleted_count": 0,
                "deleted_ids": [] as [String],
                "failures": [] as [[String: String]],
                "remaining": 0,
                "message": mode == "binding" ? "reminder_ids was empty." : "No completed reminders matched."
            ]
            return try formatJSON(response)
        }

        // #28 F1: in binding mode, enforce the "only completed" invariant the
        // tool schema promises. Filter mode always starts from
        // listReminders(completed: true) so every candidate is already
        // completed when we dispatch; no need to re-check there.
        // #31: dispatched via `reminderCleanupSource` (protocol-typed) for
        // testability.
        let onlyCompleted = (mode == "binding")
        let result = try await reminderCleanupSource.deleteRemindersBatch(
            identifiers: identifiers,
            onlyCompleted: onlyCompleted
        )
        let failedSet = Set(result.failures.map { $0.identifier })
        let deletedIds = identifiers.filter { !failedSet.contains($0) }
        let failures: [[String: String]] = result.failures.map { ["reminder_id": $0.identifier, "error": $0.error] }

        let response: [String: Any] = [
            "dry_run": false,
            "mode": mode,
            "total": total,
            "deleted_count": result.successCount,
            "deleted_ids": deletedIds,
            "failures": failures,
            "remaining": remaining
        ].merging(result.failedRowsNoteField) { $1 }   // #274
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
        let limit = try InputValidation.requireOptionalLimit(arguments)
        let detailLevel = try InputValidation.validateDetailLevel(arguments)
        let displayTimezone = try InputValidation.parseDisplayTimezone(arguments)
        let fields = try InputValidation.parseFieldsFilter(arguments)

        // Compute effective search range (same defaults as EventKitManager)
        let now = Date()
        let defaults = EventRangeQuery.defaultSearchRange(now: now)
        let effectiveStart = userStartDate ?? defaults.start
        let effectiveEnd = userEndDate ?? defaults.end

        let events = try await eventRangeReadSource.searchEvents(
            keywords: keywords,
            matchMode: matchMode,
            startDate: effectiveStart,
            endDate: effectiveEnd,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        // Apply limit. #332: this tool has no sort, so any cut, a caller's limit or the default,
        // keeps the rows closest to today and the answer says so.
        let totalCount = events.count
        let (rows, defaultLimit) = EventRangeQuery.boundedNearNow(events, requested: limit, searched: .init(start: effectiveStart, end: effectiveEnd),
                                                                  now: now, start: { $0.startDate })

        let result = rows.map { formatEventDict($0, detailLevel: detailLevel, displayTimezone: displayTimezone, fields: fields) }

        var response: [String: Any] = [
            "keywords": keywords,
            "match_mode": matchMode,
            "event_count": totalCount,
            "searched_range": [
                "start": dateFormatter.string(from: effectiveStart),
                "start_local": formatLocal(effectiveStart, in: displayTimezone),
                "end": dateFormatter.string(from: effectiveEnd),
                "end_local": formatLocal(effectiveEnd, in: displayTimezone),
                "is_default_range": userStartDate == nil || userEndDate == nil
            ] as [String: Any],
            "events": result
        ]
        if let limit = limit { response["limit"] = limit }
        if rows.count < totalCount {
            response["truncated"] = true
            response["truncation_note"] = EventRangeQuery.nearestNote(kept: rows.count, total: totalCount)
        }
        if let defaultLimit { response["default_limit"] = defaultLimit }
        // F3 (#101): echo the raw user input ("UTC" stays "UTC") rather than
        // displayTimezone.identifier (Foundation normalizes UTC to GMT).
        if displayTimezone != nil,
           let raw = arguments["display_timezone"]?.stringValue {
            response["display_timezone"] = raw
        }
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
        let limit = try InputValidation.requireOptionalLimit(arguments)
        let detailLevel = try InputValidation.validateDetailLevel(arguments)
        let displayTimezone = try InputValidation.parseDisplayTimezone(arguments)
        let fields = try InputValidation.parseFieldsFilter(arguments)

        var events = try await eventKitManager.listEvents(
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource
        )

        // Apply limit
        let totalCount = events.count
        if let limit = limit, events.count > limit {
            events = Array(events.prefix(limit))
        }

        let result = events.map { formatEventDict($0, detailLevel: detailLevel, displayTimezone: displayTimezone, fields: fields) }

        // Include the computed date range in response.
        //
        // M4: envelope `timezone` field echoes display_timezone when set
        // — `*_local` fields are rendered in *that* zone, not system tz, so
        // the envelope must agree. Pure helper to keep choice unit-testable.
        var response: [String: Any] = [
            "range": range,
            "start_date": dateFormatter.string(from: startDate),
            "start_date_local": formatLocal(startDate, in: displayTimezone),
            "end_date": dateFormatter.string(from: endDate),
            "end_date_local": formatLocal(endDate, in: displayTimezone),
            "timezone": InputValidation.envelopeTimezoneIdentifier(
                requestedDisplayTimezone: displayTimezone != nil ? arguments["display_timezone"]?.stringValue : nil
            ),
            "event_count": totalCount,
            "events": result
        ]
        // Include week_starts_on info for this_week/next_week ranges
        if range == "this_week" || range == "next_week" {
            response["week_starts_on"] = effectiveWeekStart
        }
        if let limit = limit { response["limit"] = limit }
        // F3 (#101): echo the raw user input ("UTC" stays "UTC") rather than
        // displayTimezone.identifier (Foundation normalizes UTC to GMT).
        if displayTimezone != nil,
           let raw = arguments["display_timezone"]?.stringValue {
            response["display_timezone"] = raw
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
            // #448: a misspelled timezone read naive times in the host zone. Only this row fails.
            if let problem = ToolArgumentCheck.rowProblem(tool: "create_events_batch", rowsKey: "events", row: eventDict, index: index, checksKeys: true) {
                results.append(["index": index, "success": false, "error": problem])
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
                results.append([
                    "index": index,
                    "success": false,
                    "error": EventKitErrorSanitizer.writeFailureLog(
                        handler: "createEventsBatch",
                        identifier: "\(index)",
                        error: error
                    )
                ])
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
                results.append([
                    "index": index,
                    "success": false,
                    "error": EventKitErrorSanitizer.writeFailureLog(
                        handler: "createEventsBatch",
                        identifier: "\(index)",
                        error: error
                    )
                ])
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
                results.append([
                    "index": index,
                    "success": false,
                    "error": EventKitErrorSanitizer.writeFailureLog(
                        handler: "createEventsBatch",
                        identifier: "\(index)",
                        error: error
                    )
                ])
                continue
            }

            do {
                // #207: strict boolean per item, reported like every other per-item error.
                let itemAllDay: Bool
                do {
                    itemAllDay = try InputValidation.requireOptionalBool(eventDict, key: "all_day") ?? false
                } catch {
                    results.append([
                        "index": index,
                        "success": false,
                        "error": EventKitErrorSanitizer.writeFailureLog(
                            handler: "createEventsBatch",
                            identifier: "\(index)",
                            error: error
                        )
                    ])
                    continue
                }
                try rejectAllDayTimezoneConflict(allDay: itemAllDay, timezone: batchTimezone)   // #190
                // Parse recurrence and structured location from batch item
                let batchRecurrence = try parseRecurrenceRule(from: eventDict, defaultTimezone: batchTimezone, allowsExclusions: true)
                let batchStructuredLocation = try parseStructuredLocation(from: eventDict)

                let batchNotes = eventDict["notes"]?.stringValue
                let batchLocation = eventDict["location"]?.stringValue
                try InputValidation.validateEventTextInput(title: title, notes: batchNotes, location: batchLocation, url: nil)

                let result = try await eventWriteSource.createEventValue(EventCreateRequest(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    notes: batchNotes,
                    location: batchLocation,
                    url: nil,
                    calendarName: eventDict["calendar_name"]?.stringValue,
                    calendarSource: eventDict["calendar_source"]?.stringValue,
                    isAllDay: itemAllDay,
                    alarmOffsets: nil,
                    recurrenceRule: batchRecurrence,
                    structuredLocation: batchStructuredLocation,
                    timezone: batchTimezone
                ))
                var entry: [String: Any] = [
                    "index": index,
                    "success": true,
                    "event_id": result.event.eventIdentifier ?? "",
                    "title": result.event.title ?? title
                ]
                if result.isDuplicate {
                    entry["skipped"] = true
                }
                // #182 — per-item deterministic exclusion reporting (congruent for
                // created AND skipped items, including [] — verify finding #12).
                if let excluded = batchRecurrence?.excludedOccurrenceDates {
                    entry["excluded_occurrence_dates"] = excluded.map { EventKitManager.formatExclusionDay($0, timezone: batchTimezone) }
                    entry["exclusion_count"] = excluded.count
                }
                // #372: per item, for created and skipped items alike.
                if itemAllDay {
                    let host = Calendar.gregorian(in: .current)
                    entry.merge(AllDayOffsetWarning.responseFields(
                        AllDayOffsetWarning.warnings(start: startDate, startText: startStr, end: endDate, endText: endStr, host: host),
                        hostZone: host.timeZone, skipped: result.isDuplicate)) { $1 }
                }
                results.append(entry)
            } catch {
                results.append([
                    "index": index,
                    "success": false,
                    "error": EventKitErrorSanitizer.writeFailureLog(
                        handler: "createEventsBatch",
                        identifier: "\(index)",
                        error: error
                    )
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
                let similar = try await eventWriteSource.similarEventValues(title: title, limit: 3)
                for event in similar {
                    if let eid = event.eventIdentifier, createdIds.contains(eid) { continue }
                    similarHints.append([
                        "matched_title": title,
                        "existing_title": event.title ?? "",
                        "existing_calendar": event.calendarTitle,
                        "existing_date": dateFormatter.string(from: event.startDate),
                        "existing_date_local": localDateFormatter.string(from: event.startDate)
                    ])
                }
            } catch {
                similarLookupErrors[title] = EventKitErrorSanitizer.writeFailureLog(
                    handler: "findSimilarEvents",
                    identifier: title,
                    error: error
                )
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

        let conflicts: [EKEvent]
        do {
            conflicts = try await eventKitManager.checkConflicts(
                startDate: startDate,
                endDate: endDate,
                calendarName: calendarName,
                calendarSource: calendarSource,
                excludeEventId: excludeEventId
            )
        } catch {
            throw EventRangeQuery.worded(error, for: .conflicts)
        }

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
        let deleteOriginal = try InputValidation.requireOptionalBool(arguments, key: "delete_original") ?? false

        let newEvent = try await eventCopySource.copyEventValue(
            identifier: eventId,
            toCalendarName: targetCalendar,
            toCalendarSource: targetCalendarSource,
            deleteOriginal: deleteOriginal
        )

        // A move to the event's own calendar writes nothing; report that (verify round 2 #5).
        let action = !deleteOriginal ? "copied" : (newEvent.move?.method == .unchanged ? "unchanged" : "moved")
        var response: [String: Any] = ["action": action, "title": newEvent.title ?? "", "target_calendar": targetCalendar, "new_id": newEvent.eventIdentifier ?? "unknown"]
        // #226: a move keeps the identifier within an account; say whether it changed, how the
        // event was moved, and what a fallback copy did not keep (verify #2).
        if let move = newEvent.move {
            response["id_changed"] = move.eventIdentifier != eventId
            response["method"] = move.method.rawValue
            if !move.notCarriedOver.isEmpty { response["not_carried_over"] = move.notCarriedOver }
        } else if !newEvent.notCarriedOver.isEmpty {
            // #272: a plain copy reports what it did not keep too, with the same keys.
            response["not_carried_over"] = newEvent.notCarriedOver
        }
        return try actionResult(response)
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
        // Every entry must be a string: dropping one would shift occurrence_dates onto the wrong
        // event (verify round 2 #3).
        let ids = try eventIds.map { value -> String in
            guard let id = value.stringValue else {
                throw ToolError.invalidParameter("event_ids entries must be strings")
            }
            return id
        }
        if ids.isEmpty {
            throw ToolError.invalidParameter("event_ids must contain at least one event ID")
        }
        // #226: span ('this' default / 'all') and index-aligned occurrence dates, validated
        // before any write.
        let span = try EventMovePolicy.Span.parse(arguments["span"]?.stringValue)
        var lookupFailures: [Int: EventKitError] = [:]
        var occurrenceDates = [Date?](repeating: nil, count: ids.count)
        if let present = arguments["occurrence_dates"], present != .null {
            // A present but non-array value is rejected, not ignored (verify #10).
            guard let raw = present.arrayValue else {
                throw ToolError.invalidParameter("occurrence_dates must be an array aligned with event_ids")
            }
            guard raw.count == ids.count else {
                throw ToolError.invalidParameter("occurrence_dates must have the same length as event_ids")
            }
            for (index, value) in raw.enumerated() {
                if case .null = value { continue }
                guard let text = value.stringValue else {
                    throw ToolError.invalidParameter("occurrence_dates entries must be date strings or null")
                }
                guard !text.isEmpty else { continue }
                // Date-only values are read in the event's own time zone, as delete_event does,
                // so findOccurrence searches the right day (verify #4); the zone is looked up only
                // for a value without offset (#270 verify).
                let id = ids[index]
                // #288: a failed lookup is about this event, so it fails this row and the others go
                // on. An access error is about every row, and stops the call.
                do {
                    occurrenceDates[index] = try await OccurrenceDateInput.resolve(
                        text, iso: dateFormatter, span: span.rawValue,
                        zoneLookup: { try await self.eventCopySource.eventTimeZone(identifier: id) })
                } catch let error as EventKitError {
                    guard case .eventLookupFailed = error else { throw error }
                    lookupFailures[index] = error
                }
            }
        }

        var results: [[String: Any]] = []

        for (index, eventId) in ids.enumerated() {
            do {
                if let failure = lookupFailures[index] { throw failure }
                let moved = try await eventCopySource.moveEventValue(
                    identifier: eventId,
                    occurrenceDate: occurrenceDates[index],
                    span: span,
                    toCalendarName: targetCalendar,
                    toCalendarSource: targetCalendarSource
                )
                let idChanged = moved.result.eventIdentifier != eventId
                var row: [String: Any] = [
                    "event_id": eventId,
                    "success": true,
                    "method": moved.result.method.rawValue,
                    "id_changed": idChanged,
                    "title": moved.title ?? ""
                ]
                if idChanged { row["new_event_id"] = moved.result.eventIdentifier }
                if !moved.result.notCarriedOver.isEmpty { row["not_carried_over"] = moved.result.notCarriedOver }
                results.append(row)
            } catch {
                results.append([
                    "event_id": eventId,
                    "success": false,
                    "error": EventKitErrorSanitizer.writeFailureLog(
                        handler: "moveEventsBatch",
                        identifier: eventId,
                        error: error
                    )
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
        slots: [Date?]? = nil,
        spanStr: String,
        mode: String,
        extraFields: [String: Any] = [:]
    ) async throws -> String {
        let deleteAll = spanStr == "all"

        if deleteAll {
            // Deduplicate IDs for series deletion (each series only needs one delete).
            // #185 — routed through the manager's batch method so the whole call is
            // ONE undo unit (per-id deleteEventSeries would push N separate entries).
            let uniqueIds = DetachedOccurrenceSpan.occurrenceRowsFirst(items.map(\.identifier))
            let result = try await eventBatchDeletionSource.deleteEventSeriesBatch(
                identifiers: uniqueIds, refusingOccurrenceIdentifiers: mode == "by_event_ids")
            var response: [String: Any] = [
                "dry_run": false,
                "mode": mode,
                "total": uniqueIds.count,
                "succeeded": result.successCount,
                "failed": result.failedCount,
                "span": "all"
            ]
            for (k, v) in extraFields { response[k] = v }
            if !result.failures.isEmpty {
                response["failures"] = result.failures.map { ["event_id": $0.identifier, "error": $0.error] }
            }
            // #436 (PR #465 verify r1): rows that went through the first occurrence, as delete_event
            // reports them; the call's undo leaves them out.
            if !result.throughFirstOccurrence.isEmpty {
                response["through_first_occurrence"] = result.throughFirstOccurrence.map {
                    ["event_id": $0.identifier, "occurrence_id": $0.occurrenceID]
                }
                response["undo_note"] = result.successCount > result.throughFirstOccurrence.count
                    ? Self.batchSeriesDeletedThroughOccurrenceNote : Self.batchOnlySeriesDeletedThroughOccurrenceNote
            }
            return try formatJSON(response)
        }

        let span: EKSpan = spanStr == "future" ? .futureEvents : .thisEvent
        let result = try await eventBatchDeletionSource.deleteEventsBatch(items: items, span: span, slots: slots)
        var response: [String: Any] = [
            "dry_run": false,
            "mode": mode,
            "total": items.count,
            "succeeded": result.successCount,
            "failed": result.failedCount,
            "span": spanStr
        ]
        // #325: span future items already removed with their series by an earlier item.
        if result.coveredCount > 0 { response["already_removed"] = result.coveredCount }
        for (k, v) in extraFields { response[k] = v }
        if !result.failures.isEmpty {
            response["failures"] = result.failures.map { ["event_id": $0.identifier, "error": $0.error] }
        }
        return try formatJSON(response)
    }

    /// Feature 8: Delete multiple events at once (by IDs or by date range)
    private func handleDeleteEventsBatch(arguments: [String: Value]) async throws -> String {
        let dryRun = try InputValidation.requireOptionalBool(arguments, key: "dry_run") ?? true
        let spanStr = arguments["span"]?.stringValue ?? "this"

        // Determine mode: by event_ids or by calendar + date range
        if let eventIdsArray = arguments["event_ids"]?.arrayValue {
            // Mode 1: Delete by event IDs
            let eventIds = eventIdsArray.compactMap { $0.stringValue }
            if eventIds.isEmpty {
                throw ToolError.invalidParameter("event_ids must contain at least one event ID")
            }

            if dryRun {
                // Preview mode: show what would be deleted.
                // #27: drop event.title and event.calendar.title from the
                // preview — both are attacker-controllable (malicious .ics
                // invites, shared-calendar collaborators) and the handler is
                // excluded from UntrustedContentWrapper.readTools. Echoing
                // those raw here would bypass the wrapper boundary just like
                // the original #21 F3 pattern. Callers who need titles pipe
                // through list_events (which IS wrapped).
                //
                // #416: with span all the rows run as in the real call, occurrences' own ids first,
                // and a bare id is judged with the occurrences before it gone, so the preview
                // does not refuse a row the real call deletes.
                let spanAll = spanStr == "all"
                let rows = spanAll ? DetachedOccurrenceSpan.occurrenceRowsFirst(eventIds) : eventIds
                let named = Set(eventIds)
                var gone = Set<String>()
                var preview: [[String: Any]] = []
                for id in rows {
                    do {
                        let row = try await eventBatchDeletionSource.previewEventDeletion(
                            identifier: id, span: spanStr == "future" ? .futureEvents : .thisEvent, spanAll: spanAll,
                            namedInTheCall: named, goneInTheCall: gone)
                        switch row {
                        case .refused(let refusal):
                            preview.append(["event_id": id, "error": refusal])
                        case .deletes(let start, let end):
                            if spanAll { gone.insert(id) }
                            preview.append([
                                "event_id": id,
                                "start_date_local": localDateFormatter.string(from: start),
                                "end_date_local": localDateFormatter.string(from: end)
                            ])
                        case .deletesThroughFirstOccurrence(let start, let end, let occurrenceID):
                            if spanAll { gone.insert(id) }
                            preview.append([
                                "event_id": id,
                                "start_date_local": localDateFormatter.string(from: start),
                                "end_date_local": localDateFormatter.string(from: end),
                                "occurrence_id": occurrenceID,
                                "undo_note": Self.batchPreviewThroughOccurrenceNote
                            ])
                        }
                    } catch {
                        preview.append([
                            "event_id": id,
                            // #335 item 6: the batch's own words for a refused series id.
                            "error": EventKitErrorSanitizer.writeFailureLog(
                                handler: "deleteEventsBatch",
                                identifier: id,
                                error: EventKitManager.batchRowError(error)
                            )
                        ])
                    }
                }
                let response: [String: Any] = [
                    "dry_run": true,
                    "mode": "by_event_ids",
                    "total": rows.count,
                    "events_to_delete": preview,
                    "message": "Set dry_run=false to execute deletion. Use list_events for human-readable titles/calendar names."
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

            // #325: with one bound the other side reaches EventRangeQuery.openRangeYears out (an
            // unbounded side was cut to four years by EventKit); the response states the range.
            if beforeDate == nil && afterDate == nil {
                throw ToolError.invalidParameter("At least one of before_date or after_date is required for calendar-based deletion")
            }
            guard let searched = EventRangeQuery.deletionRange(after: afterDate, before: beforeDate) else {
                throw ToolError.invalidParameter("The search range could not be computed from the given before_date / after_date")
            }
            let searchedFields: [String: Any] = [
                "searched_from": EventRangeQuery.localText(searched.start),
                "searched_to": EventRangeQuery.localText(searched.end)
            ]

            let events: [BatchDeletionListedEvent]
            do {
                events = try await eventBatchDeletionSource.listEventsForDeletion(
                    startDate: searched.start,
                    endDate: searched.end,
                    calendarName: calendarName,
                    calendarSource: calendarSource
                )
            } catch {
                throw EventRangeQuery.worded(error, for: .deletion)
            }
            // Items with per-occurrence dates (supports multiple occurrences of same series); with
            // span "future", in slot order (verify rounds 3-5).
            let deletionItems = EventRangeQuery.deletionItems(
                events.map { (identifier: $0.identifier, start: $0.start, slot: $0.slot) }, span: spanStr
            )
            let batchItems = deletionItems.map { (identifier: $0.identifier, occurrenceDate: Optional($0.occurrenceDate)) }
            // #325 verify rounds 1-3: over a range wider than EventKit's old cut (every one-sided
            // range is), refuse more than the ceiling of deletions before the dry run too, counted
            // as this call deletes (span "all" once per series). A narrower range is not limited.
            let deletions = EventRangeQuery.deletionOperations(batchItems.map(\.identifier), span: spanStr)
            try EventRangeQuery.checkDeletionSize(operations: deletions, searched: searched)

            if dryRun {
                // #27: drop event.title and event.calendar.title from the
                // preview (see Mode 1 comment for rationale). The top-level
                // `calendar` field here is the CALLER-SUPPLIED calendarName
                // (echoed back for confirmation), not a per-event echo, so it
                // stays — it's already whatever the caller specified.
                let previewLimit = EventRangeQuery.previewLimit(searched: searched)
                let previewed = previewLimit.map { Array(events.prefix($0)) } ?? events
                let preview = previewed.map { event -> [String: Any] in
                    [
                        "event_id": event.identifier ?? "",
                        "start_date_local": localDateFormatter.string(from: event.start),
                        "end_date_local": localDateFormatter.string(from: event.end)
                    ]
                }
                var response: [String: Any] = [
                    "dry_run": true,
                    "mode": "by_date_range",
                    "calendar": calendarName,
                    "total": events.count,
                    "deletions": deletions,
                    "events_to_delete": preview,
                    "message": "Set dry_run=false to execute deletion. Use list_events for human-readable titles."
                ]
                if let afterDate = afterDate { response["after_date"] = localDateFormatter.string(from: afterDate) }
                if let beforeDate = beforeDate { response["before_date"] = localDateFormatter.string(from: beforeDate) }
                response.merge(searchedFields) { $1 }
                if previewed.count < events.count { response["preview_truncated"] = true }
                return try formatJSON(response)
            }

            return try await deleteEventsWithSpan(
                items: batchItems, slots: deletionItems.map(\.slot), spanStr: spanStr, mode: "by_date_range",
                extraFields: searchedFields.merging(["calendar": calendarName]) { $1 }
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

        // #437 verify: the other tools' `calendar_name` and `calendar_source`, and `calendars`, which
        // an older calendar-management skill wrote and a cached plugin may still send. This tool
        // reads none of them, so a call with no calendar_names read every calendar.
        for key in ["calendar_name", "calendar_source", "calendars"] {
            if let value = arguments[key], value != .null {
                throw ToolError.invalidParameter("find_duplicate_events does not take \(key). Use calendar_names, an array of calendar titles; a title two accounts share reads both.")
            }
        }

        // #437: a value that is not an array of strings used to read all calendars, or fewer than named.
        var calendarNames: [String]?
        if let value = arguments["calendar_names"], value != .null {
            guard let names = value.arrayValue?.map(\.stringValue), !names.contains(nil) else {
                throw ToolError.invalidParameter("calendar_names must be an array of strings")
            }
            calendarNames = names.isEmpty ? nil : names.compactMap { $0 }
        }

        let toleranceMinutes = try InputValidation.requireIntIfPresent(arguments, key: "tolerance_minutes", default: 5)

        let search: DuplicateSearchValue
        do {
            search = try await duplicateSearchSource.findDuplicateEvents(
                calendarNames: calendarNames,
                startDate: startDate,
                endDate: endDate,
                toleranceMinutes: toleranceMinutes
            )
        } catch {
            throw EventRangeQuery.worded(error, for: .duplicates)
        }
        let duplicates = search.pairs

        let result = duplicates.map { pair -> [String: Any] in
            [
                "event1": [
                    "id": pair.event1Id,
                    "title": pair.event1Title,
                    "calendar": pair.event1Calendar,
                    "calendar_source": pair.event1CalendarSource,
                    "start_date": dateFormatter.string(from: pair.event1StartDate),
                    "start_date_local": localDateFormatter.string(from: pair.event1StartDate)
                ],
                "event2": [
                    "id": pair.event2Id,
                    "title": pair.event2Title,
                    "calendar": pair.event2Calendar,
                    "calendar_source": pair.event2CalendarSource,
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
            "calendars_checked": search.calendarsChecked,
            "tolerance_minutes": toleranceMinutes,
            "duplicate_count": duplicates.count,
            "duplicates": result
        ]
        return try formatJSON(response)
    }

    // MARK: - Event Formatting

    /// Shared event dict builder for all event-returning handlers.
    /// Includes attendees and organizer when present.
    ///
    /// Generic over `EventFormattingSource` (#103) — accepts both real `EKEvent`
    /// and test `FakeFormattableEvent`. Emission rules unchanged (key set + conditional
    /// branches preserved); only the type signature changed for runtime-anchored
    /// drift detection. Wire format is identical.
    func formatEventDict(
        _ event: some EventFormattingSource,
        detailLevel: String = "standard",
        displayTimezone: TimeZone? = nil,
        fields: Set<String>? = nil
    ) -> [String: Any] {
        let tz = displayTimezone ?? event.formatSourceTimeZone
        var dict: [String: Any] = [
            "id": event.formatID ?? "",
            "title": event.formatTitle ?? "",
            "start_date": dateFormatter.string(from: event.formatStartDate),
            "start_date_local": formatLocal(event.formatStartDate, in: tz),
            "end_date": dateFormatter.string(from: event.formatEndDate),
            "end_date_local": formatLocal(event.formatEndDate, in: tz),
            "timezone": (event.formatSourceTimeZone ?? TimeZone.current).identifier,
            // #386: the event's own zone, null when it stores none (floating, all-day included);
            // `timezone` above falls back to the host zone, so alone it cannot tell the two apart.
            "item_timezone": event.formatSourceTimeZone?.identifier ?? NSNull(),
            "is_all_day": event.formatIsAllDay,
            "calendar": event.formatCalendarTitle
        ]
        if let location = event.formatLocation { dict["location"] = location }
        if fields != nil || detailLevel != "summary" {
            if let notes = event.formatNotes { dict["notes"] = notes }
            if let url = event.formatURL { dict["url"] = url.absoluteString }
            if let rulesFragment = event.recurrenceRulesFragment {
                dict["is_recurring"] = true
                dict["recurrence_rules"] = rulesFragment
                dict["event_recurrence_rules"] = rulesFragment
            }
            if let structuredFragment = event.structuredLocationFragment {
                dict["structured_location"] = structuredFragment
            }
            if let attendees = event.attendeesFragment, !attendees.isEmpty {
                dict["attendees"] = attendees
            }
            if let organizer = event.organizerFragment {
                dict["organizer"] = organizer
            }
            // #240: the reminder shape (#231); absolute_date_local in the zone of the other *_local strings.
            dict["alarms"] = AlarmReadOutput.dictionaries(event.alarmsFragment, absolute: { [dateFormatter] in dateFormatter.string(from: $0) },
                                                          absoluteLocal: { [self] in formatLocal($0, in: tz) })
        }
        if let fields = fields {
            let allowed = fields.union(["id"])
            return dict.filter { allowed.contains($0.key) }
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

    /// Parse a flexible date string (`FlexibleDate.parse`: ISO8601 with an offset, a date-time
    /// without one, a bare date, or a time today). When `defaultTimezone` is provided and the
    /// string has no explicit offset, the time is read in that timezone instead of the system
    /// timezone. #299: read as a Gregorian date, whatever the host's region calendar.
    private func parseFlexibleDate(_ string: String, defaultTimezone: TimeZone? = nil) throws -> Date {
        try FlexibleDate.parse(string, defaultTimezone: defaultTimezone, iso: dateFormatter)
    }

    /// #267: a reminder `due_date`. A bare `YYYY-MM-DD` is a date-only reminder; anything else is
    /// parsed by `parseFlexibleDate` as an instant, as before.
    private func parseReminderDue(_ string: String) throws -> ReminderDueInput {
        try ReminderDueInput.parse(string, timed: { try parseFlexibleDate($0) })
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

    /// #182 verify fix (finding #3) — a top-level `excluded_occurrence_dates` (outside
    /// the `recurrence` object) was silently dropped: `parseRecurrenceRule` never sees
    /// top-level keys, MCP SDK does no argument validation, and the schemas don't set
    /// `additionalProperties: false`. Reject explicitly at every event/reminder handler
    /// that parses recurrence (#101 F2 — never silently drop).
    /// #190 — all_day + timezone must be rejected, not silently degraded: EventKit
    /// keeps all-day events as floating calendar days (timeZone = nil); setting a
    /// timezone after isAllDay strips the all-day flag, shifts occurrence days
    /// across the dateline, and silently defeats #182 exclusions (#186 on-device).
    private func rejectAllDayTimezoneConflict(allDay: Bool, timezone: TimeZone?) throws {
        if allDay, timezone != nil {
            throw ToolError.invalidParameter("all_day events are floating calendar days — timezone does not apply. Omit timezone (date-only start/end already name the calendar day), or set all_day to false for a timed event.")
        }
    }

    /// PR #439 verify: the same for a key of `recurrence` beside it, which nothing read (a bound left
    /// the series open-ended, `interval` a rule of every week, a `frequency` with no `recurrence` a
    /// one-off item or, on update_event, no change), and for the read tools' names for a rule. These
    /// names are this server's own, so naming them echoes nothing the caller wrote.
    private func rejectMisplacedRecurrenceKeys(in arguments: [String: Value], forReminder: Bool) throws {
        if arguments["excluded_occurrence_dates"] != nil {
            throw ToolError.invalidParameter("excluded_occurrence_dates must be inside the recurrence object (supported on create_event and create_events_batch only) — it is not a top-level parameter")
        }
        for key in RecurrenceRuleInput.inputKeys(allowsExclusions: false) where arguments[key] != nil {
            // A caller who meant the item's own date must not be sent into a rule, or to a key this
            // tool ignores: a reminder has no end_time.
            let ownDate = key != "end_date" ? "" : forReminder ? " A reminder's own date is due_date." : " An event's own end is end_time."
            throw ToolError.invalidParameter("\(key) must be inside the recurrence object, it is not a top-level parameter.\(ownDate) Nothing was written for this item.")
        }
        for key in RecurrenceRuleInput.readKeys where arguments[key] != nil {
            throw ToolError.invalidParameter("\(key) is the name the read tools use; to write a rule, pass recurrence, one object. Nothing was written for this item.")
        }
    }

    private func parseRecurrenceRule(from arguments: [String: Value], defaultTimezone: TimeZone? = nil, allowsExclusions: Bool = false,
                                     forReminder: Bool = false) throws -> RecurrenceRuleInput? {
        try rejectMisplacedRecurrenceKeys(in: arguments, forReminder: forReminder)
        // #184 — present-but-wrong-type must throw, not silently drop (#101 F2):
        // a string like "recurrence": "daily" used to vanish, creating a
        // NON-recurring event while the response looked successful.
        guard let recurrenceValue = arguments["recurrence"] else { return nil }
        guard let recurrenceDict = recurrenceValue.objectValue else {
            throw ToolError.invalidParameter("recurrence must be an object (e.g. {\"frequency\": \"daily\"}), got a non-object value")
        }
        // #434: a key that is not read is dropped, and a misspelled bound leaves a rule with no end,
        // so the series never ends. Checked first, so a misspelled frequency is named as a key. The
        // key is not echoed (#37), as delete_calendar does (#328).
        guard Set(recurrenceDict.keys).isSubset(of: RecurrenceRuleInput.inputKeys(allowsExclusions: true)) else {
            let accepted = RecurrenceRuleInput.inputKeys(allowsExclusions: allowsExclusions)
            throw ToolError.invalidParameter("recurrence accepts only \(accepted.dropLast().joined(separator: ", ")) and \(accepted[accepted.count - 1]); another key was given. Nothing was written for this item.")
        }

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

        let interval = try InputValidation.requireIntIfPresent(recurrenceDict, key: "interval", default: 1)
        // PR #420 verify round 1: EventKit raises an Objective-C exception, which Swift cannot
        // catch and which ends the server, for an interval of 0 or less and for 2^31 to 2^32
        // (measured), so the value is bounded before any rule is built.
        guard (1...RecurrenceRuleInput.maxInterval).contains(interval) else {
            throw ToolError.invalidParameter("recurrence.interval must be an integer from 1 to \(RecurrenceRuleInput.maxInterval), got \(interval)")
        }
        // #182 verify fixes (findings #4, #9) — present-but-wrong-type must throw, not
        // silently drop (#101 F2): a JSON-number end_date used to vanish, taking the
        // only implemented pre-save window bound with it; a stringly-typed
        // occurrence_count vanished while its sibling `interval` threw.
        var endDate: Date?
        if let endDateValue = recurrenceDict["end_date"] {
            guard let s = endDateValue.stringValue else {
                throw ToolError.invalidParameter("recurrence.end_date must be a date string (e.g. \"2026-09-30\"), got a non-string value")
            }
            endDate = try parseFlexibleDate(s, defaultTimezone: defaultTimezone)
        }
        var occurrenceCount: Int?
        if let countValue = recurrenceDict["occurrence_count"] {
            guard let n = countValue.intValue else {
                throw ToolError.invalidParameter("recurrence.occurrence_count must be an integer, got a non-integer value")
            }
            // PR #420 verify round 1: 0 raises the same uncatchable exception; a negative count is
            // stored as given and means nothing.
            guard (1...RecurrenceRuleInput.maxOccurrenceCount).contains(n) else {
                throw ToolError.invalidParameter("recurrence.occurrence_count must be an integer from 1 to \(RecurrenceRuleInput.maxOccurrenceCount), got \(n)")
            }
            occurrenceCount = n
        }
        // PR #439 verify: `makeRecurrenceRule` takes end_date and drops the count, with no message.
        if endDate != nil && occurrenceCount != nil {
            throw ToolError.invalidParameter("recurrence end_date and occurrence_count cannot be combined: give one of them. Nothing was written for this item.")
        }

        // PR #420 verify round 1: a day list that is not an array is refused, not dropped.
        for key in ["days_of_week", "days_of_month"] {
            if let value = recurrenceDict[key], value != .null, value.arrayValue == nil {
                throw ToolError.invalidParameter("recurrence.\(key) must be an array of integers")
            }
        }
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
        // PR #439 verify, measured on iCloud (events and reminders): a daily or weekly rule stores
        // the list, reads it back, and repeats as if it were not there, so the days asked for are
        // dropped with no message. Monthly and yearly use it. An empty list asks for nothing.
        if frequency == .daily || frequency == .weekly, daysOfMonth?.isEmpty == false {
            throw ToolError.invalidParameter("recurrence days_of_month is used by monthly and yearly rules only; a \(freqStr) rule would repeat as if it were not there. Nothing was written for this item.")
        }
        if !forReminder, RecurrenceRuleInput.countsYearsForAnEvent(frequency: frequency, interval: interval, daysOfWeek: daysOfWeek,
                                                                   daysOfMonth: daysOfMonth, occurrenceCount: occurrenceCount) {
            throw ToolError.invalidParameter("recurrence occurrence_count is not taken on a yearly event rule with interval 1 and days_of_week, because the store does not count occurrences there: a count of 6 gave 22. For those days in the start's month, use frequency monthly with interval 12, or end_date; from a later occurrence with span future a count is refused (#443). For once a year, use yearly without days_of_week. Nothing was written for this item.")
        }

        // #182 — excluded_occurrence_dates: parse + validate with zero mutation.
        // Caller gating: only create_event / create_events_batch pass
        // allowsExclusions=true; update_event / create_reminder share this parser
        // and must reject the field EXPLICITLY (never silently drop — #101 F2 rule).
        var excludedDates: [Date]?
        if let excludedValue = recurrenceDict["excluded_occurrence_dates"] {
            guard allowsExclusions else {
                throw ToolError.invalidParameter("recurrence.excluded_occurrence_dates is only supported on create_event and create_events_batch. To exclude occurrences of an existing series, use delete_event with span:\"this\".")
            }
            guard let arr = excludedValue.arrayValue else {
                throw ToolError.invalidParameter("recurrence.excluded_occurrence_dates must be an array of date strings")
            }
            guard arr.count <= 100 else {
                throw ToolError.invalidParameter("recurrence.excluded_occurrence_dates supports at most 100 dates, got \(arr.count)")
            }
            var normalizeCal = Calendar.current
            if let tz = defaultTimezone { normalizeCal.timeZone = tz }
            var seenDays = Set<Date>()
            let parsed: [Date] = try arr.enumerated().map { idx, v in
                guard let s = v.stringValue else {
                    throw ToolError.invalidParameter("recurrence.excluded_occurrence_dates[\(idx)] must be a date string")
                }
                let date = try parseFlexibleDate(s, defaultTimezone: defaultTimezone)
                let day = normalizeCal.startOfDay(for: date)
                guard seenDays.insert(day).inserted else {
                    throw ToolError.invalidParameter("recurrence.excluded_occurrence_dates[\(idx)] duplicates an earlier date (\(s) normalizes to the same calendar day)")
                }
                return date
            }
            // #182 verify fix (finding #12) — keep the explicit empty array (a legal
            // no-op) instead of folding it into "not provided", so the response can
            // echo `excluded_occurrence_dates: []` + `exclusion_count: 0`.
            excludedDates = parsed
        }

        return RecurrenceRuleInput(
            frequency: frequency,
            interval: interval,
            endDate: endDate,
            occurrenceCount: occurrenceCount,
            daysOfWeek: daysOfWeek,
            daysOfMonth: daysOfMonth,
            excludedOccurrenceDates: excludedDates
        )
    }

    private func parseStructuredLocation(from arguments: [String: Value]) throws -> StructuredLocationInput? {
        guard let dict = arguments["structured_location"]?.objectValue else { return nil }
        guard let title = dict["title"]?.stringValue else {
            throw ToolError.invalidParameter("structured_location.title is required")
        }
        return StructuredLocationInput(
            title: title,
            latitude: InputValidation.number(dict["latitude"]),
            longitude: InputValidation.number(dict["longitude"]),
            radius: InputValidation.number(dict["radius"])
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
        guard let lat = InputValidation.number(dict["latitude"]) else {
            throw ToolError.invalidParameter("location_trigger.latitude is required")
        }
        guard let lon = InputValidation.number(dict["longitude"]) else {
            throw ToolError.invalidParameter("location_trigger.longitude is required")
        }
        let radius = InputValidation.number(dict["radius"]) ?? 100
        let proximityStr = dict["proximity"]?.stringValue ?? "enter"
        let proximity: EKAlarmProximity = proximityStr == "leave" ? .leave : .enter

        return LocationTriggerInput(
            title: title, latitude: lat, longitude: lon,
            radius: radius, proximity: proximity
        )
    }

    // (#103 D4) `formatRecurrenceRule` moved to free function in
    // `EventFormattingSource.swift` so EKEvent extension's
    // `recurrenceRulesFragment` accessor can call it without needing access
    // to a Server instance method.

    // MARK: - Tag Utilities

    /// Extract #tags from notes string, returning (clean notes without tag line, array of tags)
    private func extractTags(from notes: String?) -> (cleanNotes: String?, tags: [String]) {
        ReminderTags.extract(from: notes)
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

extension ToolError: TrustedErrorMessage {}

/// `--cli` runs tool calls through the same `executeToolCall` the MCP handler uses (#223).
extension CheICalMCPServer: CLIToolExecutor {}
