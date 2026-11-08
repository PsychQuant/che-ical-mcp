import EventKit
import Foundation

/// #490: an event as the read handlers format it, copied inside the `EventKitManager` actor before
/// the result leaves it (the reminder reads' `ReminderReadSnapshot`, #476/#482). `formatEventDict`
/// reads only `EventFormattingSource`, so this value holds what each accessor answered when it was
/// built, and a response formatted from it is byte-identical to one formatted from the live event.
///
/// `@unchecked Sendable`: the fragments are `[String: Any]` holding only strings, numbers,
/// booleans, `NSNull`, and arrays and dictionaries of them, built once from the event and never
/// mutated.
/// Everything else is a Sendable value.
struct EventReadValue: EventFormattingSource, @unchecked Sendable {
    let formatID: String?
    let formatTitle: String?
    let formatStartDate: Date
    let formatEndDate: Date
    let formatSourceTimeZone: TimeZone?
    let formatIsAllDay: Bool
    let formatCalendarTitle: String
    let formatLocation: String?
    let formatNotes: String?
    let formatURL: URL?
    let recurrenceRulesFragment: [[String: Any]]?
    let structuredLocationFragment: [String: Any]?
    let attendeesFragment: [[String: Any]]?
    let organizerFragment: [String: Any]?
    let alarmsFragment: [ReminderReadSnapshot.Alarm]

    /// Reads every accessor of `event` once, where it is called: on the manager's actor for an
    /// `EKEvent`.
    init(_ event: some EventFormattingSource) {
        formatID = event.formatID
        formatTitle = event.formatTitle
        formatStartDate = event.formatStartDate
        formatEndDate = event.formatEndDate
        formatSourceTimeZone = event.formatSourceTimeZone
        formatIsAllDay = event.formatIsAllDay
        formatCalendarTitle = event.formatCalendarTitle
        formatLocation = event.formatLocation
        formatNotes = event.formatNotes
        formatURL = event.formatURL
        recurrenceRulesFragment = event.recurrenceRulesFragment
        structuredLocationFragment = event.structuredLocationFragment
        attendeesFragment = event.attendeesFragment
        organizerFragment = event.organizerFragment
        alarmsFragment = event.alarmsFragment
    }
}

/// PR #495 round 1: what a read handler filters and sorts on, read for every event of the range.
/// `index` is the event's place in the store's answer; a handler keeps rows by it.
struct EventReadKey: Sendable, Equatable {
    let index: Int
    let start: Date
    let end: Date
    let isAllDay: Bool
}

/// PR #495 round 1: a handler's choice of rows over the keys, run on the manager's actor: the
/// indices to copy whole, in output order, and whatever the handler wants back (its counts).
typealias EventRowPick<Info: Sendable> = @Sendable ([EventReadKey]) -> (keep: [Int], info: Info)

/// The rows a handler kept, copied whole, and what its pick returned.
struct EventRowsPicked<Info: Sendable>: Sendable {
    let values: [EventReadValue]
    let info: Info

    /// Reads the keys of every event, runs `pick` over them, and copies whole only the rows it
    /// keeps (an index out of range is skipped). Called on the manager's actor, so every read of an
    /// event happens there. Copying every event whole cost about 4.5 s and 350 MB more than main at
    /// 182,605 occurrences (list_events over 100 years, --cli, 2026-11-09); picking first is within
    /// 0.1 s of main and about 10 MB above it.
    static func picking<Source: EventFormattingSource>(_ events: [Source],
                                                       _ pick: ([EventReadKey]) -> (keep: [Int], info: Info)) -> EventRowsPicked {
        let keys = events.enumerated().map {
            EventReadKey(index: $0.offset, start: $0.element.formatStartDate, end: $0.element.formatEndDate,
                         isAllDay: $0.element.formatIsAllDay)
        }
        let chosen = pick(keys)
        return EventRowsPicked(values: chosen.keep.filter(events.indices.contains).map { EventReadValue(events[$0]) },
                               info: chosen.info)
    }
}

/// #490: a calendar as `list_calendars` lists it, copied inside the manager's actor.
struct CalendarReadValue: Sendable, Equatable {
    let identifier: String
    let title: String
    let typeRawValue: Int
    let allowsContentModifications: Bool
    let isSubscribed: Bool
    let sourceTitle: String
    /// nil for a calendar with no source (an unsaved one).
    let sourceType: EKSourceType?

    init(identifier: String, title: String, typeRawValue: Int, allowsContentModifications: Bool,
         isSubscribed: Bool, sourceTitle: String, sourceType: EKSourceType?) {
        self.identifier = identifier
        self.title = title
        self.typeRawValue = typeRawValue
        self.allowsContentModifications = allowsContentModifications
        self.isSubscribed = isSubscribed
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
    }

    /// Reads the calendar where it is called: on the manager's actor. `source` is implicitly
    /// unwrapped (`null_unspecified`); a calendar without one lists `""` and `Unknown` instead of
    /// trapping, which the handler did before (PR #495 round 1).
    init(_ calendar: EKCalendar) {
        let source: EKSource? = calendar.source
        self.init(identifier: calendar.calendarIdentifier, title: calendar.title, typeRawValue: calendar.type.rawValue,
                  allowsContentModifications: calendar.allowsContentModifications, isSubscribed: calendar.isSubscribed,
                  sourceTitle: source?.title ?? "", sourceType: source?.sourceType)
    }

    /// The row `list_calendars` has always written.
    var listedRow: [String: Any] {
        [
            "id": identifier,
            "title": title,
            "type": typeRawValue,
            "allowsContentModifications": allowsContentModifications,
            "isSubscribed": isSubscribed,
            "source": sourceTitle,
            "source_type": Self.sourceTypeName(sourceType)
        ]
    }

    /// `EKSourceType` as `list_calendars` names it.
    static func sourceTypeName(_ sourceType: EKSourceType?) -> String {
        guard let sourceType else { return "Unknown" }
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
}
