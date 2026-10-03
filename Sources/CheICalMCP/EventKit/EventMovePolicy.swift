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

/// What one move did. `eventIdentifier` is the identifier after the move.
struct EventMoveResult: Equatable, Sendable {
    enum Method: String, Sendable {
        case inPlace = "in_place"
        case copied
        case split
    }
    let method: Method
    let eventIdentifier: String
    /// Fields the source had that a copy did not keep. Always empty for in-place moves.
    let notCarriedOver: [String]
}

/// Orders the writes for one move (#226). Closure seam like `ExclusionExecutor`, so the
/// sequence is testable without EventKit:
/// - a refusal from the policy writes nothing;
/// - a failed in-place change is reverted (`restore`) before falling back or refusing.
enum EventMoveExecutor {
    typealias Copied = (identifier: String, notCarriedOver: [String])

    static func run(_ input: EventMovePolicy.Input,
                    inPlace: () throws -> String,
                    restore: () -> Void,
                    copy: () throws -> Copied,
                    split: () throws -> Copied) throws -> EventMoveResult {
        switch EventMovePolicy.plan(input) {
        case .refuse(let reason):
            throw EventKitError.moveRefused(reason: reason)
        case .split:
            let result = try split()
            return EventMoveResult(method: .split, eventIdentifier: result.identifier, notCarriedOver: result.notCarriedOver)
        case .inPlace:
            do {
                return EventMoveResult(method: .inPlace, eventIdentifier: try inPlace(), notCarriedOver: [])
            } catch {
                restore()
                switch EventMovePolicy.afterInPlaceFailure(input) {
                case .refuse(let reason):
                    throw EventKitError.moveRefused(reason: reason)
                case .copy:
                    let result = try copy()
                    return EventMoveResult(method: .copied, eventIdentifier: result.identifier, notCarriedOver: result.notCarriedOver)
                }
            }
        }
    }
}
