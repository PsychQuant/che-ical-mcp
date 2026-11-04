import EventKit
import Foundation

/// The fields of an `update_event` call, as `EventKitManager.updateEvent` takes them.
struct EventUpdateRequest: Sendable {
    let identifier: String
    var title: String? = nil
    var startDate: Date? = nil
    var endDate: Date? = nil
    var notes: String? = nil
    var location: String? = nil
    var url: String? = nil
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var isAllDay: Bool? = nil
    var alarmOffsets: [Int]? = nil
    var recurrenceRule: RecurrenceRuleInput? = nil
    var clearRecurrence = false
    var structuredLocation: StructuredLocationInput? = nil
    var span: EKSpan = .thisEvent
    var occurrenceDate: Date? = nil
    var applyToAll = false
    var timezone: TimeZone? = nil
    var clearTimezone = false
}

/// The fields of a `create_event` call (or one `create_events_batch` item), as
/// `EventKitManager.createEvent` takes them.
struct EventCreateRequest: Sendable {
    let title: String
    let startDate: Date
    let endDate: Date
    var notes: String? = nil
    var location: String? = nil
    var url: String? = nil
    var calendarName: String? = nil
    var calendarSource: String? = nil
    var isAllDay = false
    var alarmOffsets: [Int]? = nil
    var recurrenceRule: RecurrenceRuleInput? = nil
    var structuredLocation: StructuredLocationInput? = nil
    var timezone: TimeZone? = nil
}

/// A create's saved event, and whether it was an existing duplicate (`skipped`).
struct EventCreateValue: Sendable, Equatable {
    let event: EventWriteValue
    let isDuplicate: Bool
}

/// The saved event, as the write handlers read it for their response.
struct EventWriteValue: Sendable, Equatable {
    let eventIdentifier: String?
    let title: String?
    let isAllDay: Bool
    let startDate: Date
    let endDate: Date
    /// Set only by `update_event` when the save was of one occurrence edited on its own (span
    /// "this"): the identifier of its series after the save (#268 verify round 2).
    var seriesIdentifier: String? = nil
    /// Set only by `update_event` when `occurrence_date` matched one occurrence of a series (not
    /// span "all"): that occurrence's start before the update, and the zone it was matched in
    /// (#383 verify).
    var matchedOccurrence: MatchedOccurrence? = nil
}

/// The occurrence an `update_event` call's `occurrence_date` matched (#383 verify).
struct MatchedOccurrence: Sendable, Equatable {
    let start: Date
    let zone: TimeZone?
}

/// `update_event`'s `occurrence_start`: the matched occurrence's start as ISO 8601 with the offset
/// of the zone it was matched in, this Mac's zone for a floating event (#383 verify).
enum OccurrenceStart {
    static func string(_ start: Date, zone: TimeZone?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = zone ?? .current
        return formatter.string(from: start)
    }
}

/// Narrow seam for the event write handlers (CLAUDE.md "Test Seam Convention"): #268, so a test
/// can return a saved event whose identifier differs from the one the call named; #372, so the
/// all-day offset warnings of `create_event`, `create_events_batch` and `update_event` are tested
/// through the handlers.
protocol EventWriteSource: Sendable {
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue
    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue
    /// `create_events_batch`'s advisory lookup of existing events with a similar title (kept on the
    /// seam so a handler test does not read the host's calendars).
    func similarEventValues(title: String, limit: Int) async throws -> [SimilarEventValue]
    /// #383: the zone `update_event` reads an offset-less `occurrence_date` in, the zone its search
    /// takes the day boundary in (`EventKitManager.occurrenceDateTimeZone`, shared with
    /// `delete_event` and `move_events_batch` since #270).
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone?
}

/// An existing event `create_events_batch` names as similar to a batch title.
struct SimilarEventValue: Sendable, Equatable {
    let eventIdentifier: String?
    let title: String?
    let calendarTitle: String
    let startDate: Date
}

extension EventWriteValue {
    init(_ event: EKEvent, seriesIdentifier: String? = nil) {
        self.init(eventIdentifier: event.eventIdentifier, title: event.title, isAllDay: event.isAllDay,
                  startDate: event.startDate, endDate: event.endDate, seriesIdentifier: seriesIdentifier)
    }
}

extension EventKitManager: EventWriteSource {
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        let saved = try await updateEvent(
            identifier: request.identifier, title: request.title,
            startDate: request.startDate, endDate: request.endDate,
            notes: request.notes, location: request.location, url: request.url,
            calendarName: request.calendarName, calendarSource: request.calendarSource,
            isAllDay: request.isAllDay, alarmOffsets: request.alarmOffsets,
            recurrenceRule: request.recurrenceRule, clearRecurrence: request.clearRecurrence,
            structuredLocation: request.structuredLocation, span: request.span,
            occurrenceDate: request.occurrenceDate, applyToAll: request.applyToAll,
            timezone: request.timezone, clearTimezone: request.clearTimezone)
        var value = EventWriteValue(saved.event, seriesIdentifier: saved.seriesIdentifier)
        value.matchedOccurrence = saved.matchedOccurrence
        return value
    }

    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        let result = try await createEvent(
            title: request.title, startDate: request.startDate, endDate: request.endDate,
            notes: request.notes, location: request.location, url: request.url,
            calendarName: request.calendarName, calendarSource: request.calendarSource,
            isAllDay: request.isAllDay, alarmOffsets: request.alarmOffsets,
            recurrenceRule: request.recurrenceRule, structuredLocation: request.structuredLocation,
            timezone: request.timezone)
        return EventCreateValue(event: EventWriteValue(result.event), isDuplicate: result.isDuplicate)
    }

    func similarEventValues(title: String, limit: Int) async throws -> [SimilarEventValue] {
        try await findSimilarEvents(title: title, limit: limit).map {
            SimilarEventValue(eventIdentifier: $0.eventIdentifier, title: $0.title,
                              calendarTitle: $0.calendar.title, startDate: $0.startDate)
        }
    }
}
