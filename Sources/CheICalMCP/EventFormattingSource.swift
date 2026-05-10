import EventKit
import Foundation

/// Test seam protocol for `formatEventDict` — abstracts the EKEvent accessors
/// the formatter reads, enabling fake event injection in drift detection tests
/// without TCC permission.
///
/// Production: `EKEvent` conforms via extension below.
/// Tests: `FakeFormattableEvent` (in Tests/Helpers/) provides kitchen-sink defaults.
///
/// **Naming convention**: protocol property names are intentionally **prefixed**
/// (e.g. `formatID`, `formatTitle`) rather than reusing EKEvent's native names
/// (`eventIdentifier`, `title`). This avoids Swift's protocol-conformance
/// ambiguity when EKEvent's properties are imported with IUO types
/// (`String!` / `Date!`) — exact-match conformance fails on type-printing
/// equality even when types are nominally identical.
///
/// Fragment-based design (per #103 D1): conditional fields like recurrence rules,
/// structured location, attendees, and organizer are exposed as pre-formatted
/// opaque blobs rather than raw EventKit types. This avoids the need to abstract
/// EKRecurrenceRule / EKStructuredLocation / EKParticipant (the latter is not
/// constructible in test environments).
///
/// Drift test only cares about emitted **key set**, not fragment content — so
/// a fake returning `[:]` opaque dict drives the same emission path as a real
/// EKEvent returning rich fragment data.
protocol EventFormattingSource {
    // MARK: - Always-emitted accessors (prefixed to avoid EKEvent collision)
    var formatID: String? { get }
    var formatTitle: String? { get }
    var formatStartDate: Date { get }
    var formatEndDate: Date { get }
    var formatSourceTimeZone: TimeZone? { get }
    var formatIsAllDay: Bool { get }
    var formatCalendarTitle: String { get }

    // MARK: - Conditional accessors (nil/empty → skip emission)
    var formatLocation: String? { get }
    var formatNotes: String? { get }
    var formatURL: URL? { get }

    // MARK: - Fragment accessors (pre-formatted opaque blobs;
    //         nil → skip emission of corresponding key)
    var recurrenceRulesFragment: [[String: Any]]? { get }
    var structuredLocationFragment: [String: Any]? { get }
    var attendeesFragment: [[String: Any]]? { get }
    var organizerFragment: [String: Any]? { get }
}

// MARK: - EKEvent conformance

/// Module-level formatter used by `formatRecurrenceRule` for `end_date`
/// formatting. Stateless (no per-call configuration), safe to share.
let eventFormattingDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.timeZone = TimeZone.current
    return f
}()

extension EKEvent: EventFormattingSource {
    var formatID: String? { eventIdentifier }
    var formatTitle: String? { title }
    var formatStartDate: Date { startDate }
    var formatEndDate: Date { endDate }
    var formatSourceTimeZone: TimeZone? { timeZone }
    var formatIsAllDay: Bool { isAllDay }
    var formatCalendarTitle: String { calendar.title }
    var formatLocation: String? { location }
    var formatNotes: String? { notes }
    var formatURL: URL? { url }

    var recurrenceRulesFragment: [[String: Any]]? {
        guard hasRecurrenceRules, let rules = recurrenceRules else { return nil }
        return rules.map { formatRecurrenceRule($0, dateFormatter: eventFormattingDateFormatter) }
    }

    var structuredLocationFragment: [String: Any]? {
        guard let structured = structuredLocation else { return nil }
        var dict: [String: Any] = ["title": structured.title ?? ""]
        if let geo = structured.geoLocation {
            dict["latitude"] = geo.coordinate.latitude
            dict["longitude"] = geo.coordinate.longitude
        }
        if structured.radius > 0 { dict["radius"] = structured.radius }
        return dict
    }

    var attendeesFragment: [[String: Any]]? {
        formatAttendeesInfo(self).attendees
    }

    var organizerFragment: [String: Any]? {
        formatAttendeesInfo(self).organizer
    }
}

// MARK: - Free recurrence-rule formatter

/// Format a single `EKRecurrenceRule` as a JSON-friendly dict. Extracted from
/// `CheICalMCPServer.formatRecurrenceRule` (#103 D4) so that EKEvent extension's
/// `recurrenceRulesFragment` accessor can call it without needing access to a
/// Server instance method.
///
/// - Parameter rule: the recurrence rule to format
/// - Parameter dateFormatter: formatter for `end_date` when bounded
/// - Returns: dict with `frequency` / `interval`, plus optional `end_date`,
///   `occurrence_count`, `days_of_week`, `days_of_month`
func formatRecurrenceRule(
    _ rule: EKRecurrenceRule,
    dateFormatter: DateFormatter
) -> [String: Any] {
    var dict: [String: Any] = [
        "frequency": ["daily", "weekly", "monthly", "yearly"][rule.frequency.rawValue],
        "interval": rule.interval
    ]
    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate {
            dict["end_date"] = dateFormatter.string(from: endDate)
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
