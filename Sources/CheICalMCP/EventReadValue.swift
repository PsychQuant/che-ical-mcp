import EventKit
import Foundation

/// #490: an event as the read handlers format it, copied inside the `EventKitManager` actor before
/// the result leaves it (the reminder reads' `ReminderReadSnapshot`, #476/#482). `formatEventDict`
/// reads only `EventFormattingSource`, so this value holds what each accessor answered when it was
/// built, and a response formatted from it is byte-identical to one formatted from the live event.
///
/// `@unchecked Sendable`: the fragments are `[String: Any]` holding only strings, numbers and
/// booleans (and arrays and dictionaries of them), built once from the event and never mutated.
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

/// #490: a calendar as `list_calendars` lists it, copied inside the manager's actor.
struct CalendarReadValue: Sendable, Equatable {
    let identifier: String
    let title: String
    let typeRawValue: Int
    let allowsContentModifications: Bool
    let isSubscribed: Bool
    let sourceTitle: String
    let sourceType: EKSourceType

    init(identifier: String, title: String, typeRawValue: Int, allowsContentModifications: Bool,
         isSubscribed: Bool, sourceTitle: String, sourceType: EKSourceType) {
        self.identifier = identifier
        self.title = title
        self.typeRawValue = typeRawValue
        self.allowsContentModifications = allowsContentModifications
        self.isSubscribed = isSubscribed
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
    }

    /// Reads the calendar where it is called: on the manager's actor.
    init(_ calendar: EKCalendar) {
        self.init(identifier: calendar.calendarIdentifier, title: calendar.title, typeRawValue: calendar.type.rawValue,
                  allowsContentModifications: calendar.allowsContentModifications, isSubscribed: calendar.isSubscribed,
                  sourceTitle: calendar.source.title, sourceType: calendar.source.sourceType)
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
    static func sourceTypeName(_ sourceType: EKSourceType) -> String {
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
