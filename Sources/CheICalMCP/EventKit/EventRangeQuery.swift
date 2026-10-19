import CheMCPKit
import EventKit
import Foundation

/// #325: listing events over a range of any length.
///
/// `EKEventStore.predicateForEvents(withStart:end:calendars:)` does not fail when the span is too
/// long: it cuts the span at its first ~four years and returns what falls there. On device
/// (iCloud, 2026-10-19) the cut was at start + 1461 days: a 1462-day query missed an event 12
/// hours before its end, and a nine-year query from 2018 returned only the 2019 event of five.
/// The result looks complete, which is how a non-empty calendar came close to being deleted.
///
/// So a range is split into consecutive spans of at most 1460 days (the bound the undo scan
/// already uses, `UndoPostState.seriesScanWindow`), one query per span, and the results are
/// merged. An event that overlaps two spans is matched by both and kept once; the occurrences of
/// one series share an identifier and differ by start, so the key carries both.
enum EventRangeQuery {
    /// One span's length, on the safe side of EventKit's 1461-day cut.
    static let maxSpanDays = 1460
    /// The most spans one call may query (about 400 years); a wider range is refused, not cut.
    static let maxSpans = 100

    struct Span: Equatable {
        let start: Date
        let end: Date
    }

    enum RangeError: LocalizedError, Equatable {
        case tooWide(days: Int)

        var errorDescription: String? {
            switch self {
            case .tooWide(let days):
                return "Date range too wide: \(days) days. At most 400 years (\(EventRangeQuery.maxSpans) queries of \(EventRangeQuery.maxSpanDays) days) can be searched in one call; narrow the range."
            }
        }
    }

    /// `[start, end)` as consecutive spans of at most `maxSpanDays`. An empty or inverted range
    /// is returned as is, as one span: EventKit matches nothing for it, as before.
    static func spans(from start: Date, to end: Date) throws -> [Span] {
        guard end > start else { return [Span(start: start, end: end)] }
        let length = TimeInterval(maxSpanDays) * 86_400
        let total = end.timeIntervalSince(start)
        let count = Int((total / length).rounded(.up))
        guard count <= maxSpans else {
            throw RangeError.tooWide(days: Int((total / 86_400).rounded(.up)))
        }
        return (0..<count).map { index in
            let spanStart = start.addingTimeInterval(Double(index) * length)
            let spanEnd = index == count - 1 ? end : start.addingTimeInterval(Double(index + 1) * length)
            return Span(start: spanStart, end: spanEnd)
        }
    }

    /// Runs `query` once per span and returns the results in span order, each occurrence once.
    static func collect<Item>(from start: Date, to end: Date,
                              query: (Date, Date) -> [Item],
                              key: (Item) -> String) throws -> [Item] {
        var seen = Set<String>()
        var found: [Item] = []
        for span in try spans(from: start, to: end) {
            for item in query(span.start, span.end) where seen.insert(key(item)).inserted {
                found.append(item)
            }
        }
        return found
    }

    /// One occurrence: the event identifier (shared by a series' unedited occurrences) and its
    /// start. `fallbackIdentifier` (the calendar item identifier) stands in when an event has no
    /// event identifier yet, so two such events at the same start are not merged.
    static func occurrenceKey(eventIdentifier: String?, fallbackIdentifier: String, start: Date) -> String {
        let id = (eventIdentifier?.isEmpty == false ? eventIdentifier : nil) ?? "item:\(fallbackIdentifier)"
        return "\(id)|\(start.timeIntervalSinceReferenceDate)"
    }
}

extension EventRangeQuery.RangeError: TrustedErrorMessage {}

extension EventKitManager {
    /// The events overlapping `[start, end)` in `calendars` (all event calendars when nil), over
    /// a range of any length up to `EventRangeQuery.maxSpans` spans. Every caller-given range
    /// reaches EventKit through here (#325; pinned by `EventRangeQueryTests`).
    func events(from start: Date, to end: Date, calendars: [EKCalendar]?) throws -> [EKEvent] {
        try EventRangeQuery.collect(
            from: start, to: end,
            query: { eventStore.events(matching: eventStore.predicateForEvents(withStart: $0, end: $1, calendars: calendars)) },
            key: { EventRangeQuery.occurrenceKey(eventIdentifier: $0.eventIdentifier,
                                                 fallbackIdentifier: $0.calendarItemIdentifier,
                                                 start: $0.startDate) }
        )
    }
}
