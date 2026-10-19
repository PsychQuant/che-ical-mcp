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

    /// EventKit's own cut (measured, #325): a range of at most this many days was already
    /// returned in full before #325, so nothing changes for it.
    static let previousCutDays = 1461

    /// The most deletions one `delete_events_batch` by date range may make over a range wider than
    /// `previousCutDays` (verify rounds 1-2). Only those ranges reach more than they did before #325:
    /// a one-sided range now reaches 100 years, and an open-ended daily series alone is about 36,500
    /// occurrences there, all in one `.batch` undo entry that restores each as a one-off event. A
    /// narrower range is not limited: it behaves exactly as before. Counted as deletions, not
    /// occurrences: span "all" deletes each series once.
    static let maxDeletionOccurrences = 2000

    enum RangeError: LocalizedError, Equatable {
        case tooWide(days: Int)
        case tooManyToDelete(count: Int, from: String, to: String)

        var errorDescription: String? {
            switch self {
            case .tooWide(let days):
                let number = NumberFormatter()
                number.locale = Locale(identifier: "en_US_POSIX")
                number.numberStyle = .decimal
                number.usesGroupingSeparator = true
                number.groupingSeparator = ","
                let ceiling = number.string(from: NSNumber(value: EventRangeQuery.maxSpans * EventRangeQuery.maxSpanDays)) ?? "\(EventRangeQuery.maxSpans * EventRangeQuery.maxSpanDays)"
                return "Date range too wide: \(days) days. At most \(ceiling) days (about 400 years; \(EventRangeQuery.maxSpans) queries of \(EventRangeQuery.maxSpanDays) days) can be searched in one call; narrow the range."
            case .tooManyToDelete(let count, let from, let to):
                return "Refusing to delete: from \(from) to \(to) this call would make \(count) deletions, more than the \(EventRangeQuery.maxDeletionOccurrences) allowed for a range wider than \(EventRangeQuery.previousCutDays) days. Nothing was deleted. Narrow the range with before_date and after_date."
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

    /// How far `delete_events_batch` by date range searches past the one bound it was given.
    static let openRangeYears = 100

    /// The range `delete_events_batch` by date range searches. With one bound, the open side
    /// reaches `openRangeYears` out instead of `Date.distantPast` / `distantFuture`: those were
    /// cut by EventKit to four years (one bound only: nothing found before `before_date`, events
    /// left undeleted after `after_date + 4 years`), and chunking them would take about a thousand
    /// queries. The response states the range, so the horizon is never claimed as everything.
    /// Nil with no bound; the handler refuses that case itself.
    static func deletionRange(after: Date?, before: Date?) -> Span? {
        let gregorian = Calendar.gregorian(in: TimeZone(identifier: "UTC")!)
        switch (after, before) {
        case let (after?, before?):
            return Span(start: after, end: before)
        case let (after?, nil):
            return gregorian.date(byAdding: .year, value: openRangeYears, to: after).map { Span(start: after, end: $0) }
        case let (nil, before?):
            return gregorian.date(byAdding: .year, value: -openRangeYears, to: before).map { Span(start: $0, end: before) }
        case (nil, nil):
            return nil
        }
    }

    /// Whether `range` is wider than EventKit's old cut, i.e. one #325 widened.
    static func widensPreviousCut(_ range: Span) -> Bool {
        range.end.timeIntervalSince(range.start) > TimeInterval(previousCutDays) * 86_400
    }

    /// The deletions a by-date-range call makes for these listed events: events without an
    /// identifier are skipped by the delete path, and span "all" deletes each series once.
    static func deletionOperations(identifiers: [String?], deleteAll: Bool) -> Int {
        let ids = identifiers.compactMap { $0 }
        return deleteAll ? Set(ids).count : ids.count
    }

    /// Refuses, dry run included, a call over a range wider than `previousCutDays` that would make
    /// more than `maxDeletionOccurrences` deletions, before anything is deleted. `fromText` and
    /// `toText` are the range as `searched_from` / `searched_to` state it.
    static func checkDeletionSize(operations: Int, searched: Span, fromText: String, toText: String) throws {
        guard widensPreviousCut(searched), operations > maxDeletionOccurrences else { return }
        throw RangeError.tooManyToDelete(count: operations, from: fromText, to: toText)
    }

    /// The most dry-run preview rows over `searched`: bounded only where the range is wider than
    /// the old cut (a span "all" call within the deletion ceiling can still list many occurrences).
    static func previewLimit(searched: Span) -> Int? {
        widensPreviousCut(searched) ? maxDeletionOccurrences : nil
    }

    /// One occurrence: the event identifier (shared by a series' unedited occurrences) and its
    /// start. `fallbackIdentifier` (the calendar item identifier) stands in when an event has no
    /// event identifier yet, so two such events at the same start are not merged.
    static func occurrenceKey(eventIdentifier: String?, fallbackIdentifier: String, start: Date,
                              occurrenceDate: Date? = nil) -> String {
        let id = (eventIdentifier?.isEmpty == false ? eventIdentifier : nil) ?? "item:\(fallbackIdentifier)"
        // The rule slot too (verify round 2): an occurrence edited onto another's start, on a store
        // that keeps the series identifier for it, is a different occurrence.
        let slot = occurrenceDate.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "-"
        return "\(id)|\(start.timeIntervalSinceReferenceDate)|\(slot)"
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
                                                 start: $0.startDate,
                                                 occurrenceDate: $0.occurrenceDate) }
        )
    }
}
