import Foundation
@testable import CheICalMCP

/// Test fake conforming to `EventFormattingSource` (#103). Provides
/// kitchen-sink defaults — every conditional accessor returns non-nil so
/// driving a `FakeFormattableEvent` through `formatEventDict` triggers **all**
/// conditional emission paths.
///
/// Intended primary use: M3 drift detection test
/// (`testValidEventFieldsMatchesFormatEventDictKeys`). Future event-formatting
/// tests can construct customized instances by overriding init parameters.
///
/// Fragment accessors return opaque non-empty values — drift test only cares
/// about emitted **key set** in `formatEventDict`'s output dict, not the
/// fragment content. So returning `[["frequency": "weekly"]]` for
/// `recurrenceRulesFragment` is sufficient to drive `dict["recurrence_rules"] = ...`
/// emission.
///
/// **Naming**: not `*Tests`-suffixed (per CLAUDE.md `Helpers/` carve-out, #83).
struct FakeFormattableEvent: EventFormattingSource {
    var formatID: String?
    var formatTitle: String?
    var formatStartDate: Date
    var formatEndDate: Date
    var formatSourceTimeZone: TimeZone?
    var formatIsAllDay: Bool
    var formatCalendarTitle: String

    var formatLocation: String?
    var formatNotes: String?
    var formatURL: URL?

    var recurrenceRulesFragment: [[String: Any]]?
    var structuredLocationFragment: [String: Any]?
    var attendeesFragment: [[String: Any]]?
    var organizerFragment: [String: Any]?

    /// Default initializer — all conditional accessors set to non-nil values
    /// so the fake triggers every conditional emission path in `formatEventDict`.
    /// Override individual properties via the property-list initializer below
    /// when a specific test wants to suppress a branch.
    init(
        formatID: String? = "fake-event-id",
        formatTitle: String? = "Fake Event Title",
        formatStartDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        formatEndDate: Date = Date(timeIntervalSince1970: 1_700_003_600),
        formatSourceTimeZone: TimeZone? = TimeZone(identifier: "UTC"),
        formatIsAllDay: Bool = false,
        formatCalendarTitle: String = "Fake Calendar",

        formatLocation: String? = "Fake Location",
        formatNotes: String? = "Fake notes content",
        formatURL: URL? = URL(string: "https://example.com/fake"),

        // Fragments default to non-empty opaque blobs to trigger emission of
        // the corresponding keys. Drift test inspects key set, not values.
        recurrenceRulesFragment: [[String: Any]]? = [["frequency": "weekly", "interval": 1]],
        structuredLocationFragment: [String: Any]? = ["title": "Fake structured loc"],
        attendeesFragment: [[String: Any]]? = [["name": "Fake Attendee", "email": "a@example.com"]],
        organizerFragment: [String: Any]? = ["name": "Fake Organizer", "email": "org@example.com"]
    ) {
        self.formatID = formatID
        self.formatTitle = formatTitle
        self.formatStartDate = formatStartDate
        self.formatEndDate = formatEndDate
        self.formatSourceTimeZone = formatSourceTimeZone
        self.formatIsAllDay = formatIsAllDay
        self.formatCalendarTitle = formatCalendarTitle
        self.formatLocation = formatLocation
        self.formatNotes = formatNotes
        self.formatURL = formatURL
        self.recurrenceRulesFragment = recurrenceRulesFragment
        self.structuredLocationFragment = structuredLocationFragment
        self.attendeesFragment = attendeesFragment
        self.organizerFragment = organizerFragment
    }
}
