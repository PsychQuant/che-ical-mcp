/// #226: how `move_events_batch` (and `copy_event` with `delete_original`) moves an event.
///
/// Decided 2026-10-04 and checked on device the same day:
/// - Move in place first by reassigning the event's calendar. This keeps recurrence,
///   attendees and every other field. Across accounts EventKit still performs the move but
///   returns a new identifier, so callers compare identifiers rather than assume.
/// - `span: this` on a recurring event splits the occurrence out by copy + remove. An
///   in-place calendar change on one occurrence moves the whole series.
/// - Refuse only when the copy path would lose recurrence or attendees.
///
/// Refusal reasons are fixed strings: no EventKit text, no user-controlled values.
enum EventMovePolicy {
    enum Span: String, Sendable {
        case this, all

        /// `nil` means the default, `this` (same default as the other event tools).
        static func parse(_ raw: String?) throws -> Span {
            guard let raw else { return .this }
            guard let span = Span(rawValue: raw) else {
                throw ToolError.invalidParameter("span must be 'this' or 'all'")
            }
            return span
        }
    }

    struct Input: Equatable, Sendable {
        let isRecurring: Bool
        let span: Span
        let hasOccurrenceDate: Bool
        let attendeeCount: Int
    }

    enum Plan: Equatable, Sendable {
        case inPlace
        case split
        case refuse(String)
    }

    enum Fallback: Equatable, Sendable {
        case copy
        case refuse(String)
    }

    static func plan(_ input: Input) -> Plan {
        guard input.isRecurring, input.span == .this else { return .inPlace }
        guard input.hasOccurrenceDate else {
            return .refuse("For a recurring event, occurrence_date is required to move one occurrence; use span 'all' to move the whole series.")
        }
        guard input.attendeeCount == 0 else {
            return .refuse("This occurrence has attendees; moving it alone would copy it and drop the attendees. Use span 'all' to move the whole series in place.")
        }
        return .split
    }

    static func afterInPlaceFailure(_ input: Input) -> Fallback {
        if input.isRecurring {
            return .refuse("The calendar could not be changed in place, and a copy would drop the recurrence.")
        }
        if input.attendeeCount > 0 {
            return .refuse("The calendar could not be changed in place, and a copy would drop the attendees.")
        }
        return .copy
    }
}
