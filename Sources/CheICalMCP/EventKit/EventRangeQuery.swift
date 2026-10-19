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
    /// narrower range is not limited by it. A one-sided range is always
    /// wider (it reaches 100 years), so it is always under this limit (verify round 3, maintainer's
    /// choice): before #325 the same call deleted only the first four years, silently. Counted as
    /// deletions, not occurrences: span "all" and span "future" delete each series once.
    static let maxDeletionOccurrences = 2000

    /// The most candidate comparisons one `find_duplicate_events` may make over a range wider than
    /// `previousCutDays` (verify round 3). Two calendars holding the same daily series, with a
    /// tolerance covering the range, pair every occurrence with every other: 1461² ≈ 2.1 million
    /// over the old four-year cut, about 1.3 billion over 100 years, held in memory and sorted on
    /// the manager's actor. This limit is about the old worst case; a narrower range is not limited.
    static let maxDuplicateComparisons = 2_000_000

    enum RangeError: LocalizedError, Equatable {
        case tooWide(days: Int)
        case tooManyToDelete(count: Int, from: Date, to: Date)
        case tooManyComparisons(limit: Int)

        var errorDescription: String? {
            switch self {
            case .tooWide(let days):
                let ceiling = Self.grouped(EventRangeQuery.maxSpans * EventRangeQuery.maxSpanDays)
                return "Date range too wide: \(days) days. At most \(ceiling) days (about 400 years; \(EventRangeQuery.maxSpans) queries of \(EventRangeQuery.maxSpanDays) days) can be searched in one call; narrow the range."
            case .tooManyToDelete(let count, let from, let to):
                return "Refusing to delete: from \(EventRangeQuery.localText(from)) to \(EventRangeQuery.localText(to)) this call would make \(count) deletions, more than the \(EventRangeQuery.maxDeletionOccurrences) allowed for a range wider than \(EventRangeQuery.previousCutDays) days. Nothing was deleted. Give both after_date and before_date, at most \(EventRangeQuery.previousCutDays - 1) days apart."
            case .tooManyComparisons(let limit):
                return "Stopped: finding duplicates over a range wider than \(EventRangeQuery.previousCutDays) days took more than \(Self.grouped(limit)) comparisons. Nothing was returned. Narrow the range or lower tolerance_minutes."
            }
        }

        private static func grouped(_ value: Int) -> String {
            let number = NumberFormatter()
            number.locale = Locale(identifier: "en_US_POSIX")
            number.numberStyle = .decimal
            number.usesGroupingSeparator = true
            number.groupingSeparator = ","
            return number.string(from: NSNumber(value: value)) ?? "\(value)"
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
    /// Each span after the first is queried from one second before its start (verify round 3): a
    /// zero-length event exactly on a boundary overlaps neither half-open span under a strict
    /// overlap test. The key drops what both spans return; nothing before `start` is queried.
    static func collect<Item>(from start: Date, to end: Date,
                              query: (Date, Date) -> [Item],
                              key: (Item) -> String) throws -> [Item] {
        var seen = Set<String>()
        var found: [Item] = []
        for span in try spans(from: start, to: end) {
            let from = span.start > start ? max(start, span.start.addingTimeInterval(-1)) : span.start
            for item in query(from, span.end) where seen.insert(key(item)).inserted {
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

    struct DeletionItem: Equatable {
        let identifier: String
        /// The occurrence's start: what `findOccurrence` looks it up by.
        let occurrenceDate: Date
        /// The occurrence's slot in its series (`EKEvent.occurrenceDate`), which differs from its
        /// start when it was moved; what a span "future" removal is measured by (verify round 5).
        var slot: Date? = nil
    }

    /// What a by-date-range call sends to the delete path, in order: events without an identifier
    /// are skipped, as the delete path always skipped them. With span "future" every listed
    /// occurrence is sent in slot order (verify rounds 3-5), and `deleteEventsBatch` skips the ones
    /// an earlier removal of the same series already reached (`FutureDeletionCoverage`): each used
    /// to cost one EventKit lookup and come back as a failure ("No occurrence found"), about
    /// 36,500 for a daily series over 100 years. Slot order, not start order: the removal from a
    /// series' earliest slot reaches every later slot, so a series is removed once, whatever was
    /// moved where. Sending them all keeps the old fallback when the earliest cannot be removed.
    static func deletionItems(_ listed: [(identifier: String?, start: Date, slot: Date?)], span: String) -> [DeletionItem] {
        let items = listed.compactMap { event in
            event.identifier.map { DeletionItem(identifier: $0, occurrenceDate: event.start, slot: event.slot) }
        }
        guard span == "future" else { return items }
        return items.enumerated()
            .sorted { (($0.element.slot ?? $0.element.occurrenceDate), $0.offset) < (($1.element.slot ?? $1.element.occurrenceDate), $1.offset) }
            .map(\.element)
    }

    /// The deletions these items make, at most: span "all" deletes each series once, whole, and
    /// span "future" each series once from its earliest listed slot. An occurrence edited on its
    /// own that has its own identifier (`<series>/RID=…` on iCloud) counts as one more, even when
    /// its series' removal then takes it (it is reported as already_removed).
    static func deletionOperations(_ identifiers: [String], span: String) -> Int {
        span == "all" || span == "future" ? Set(identifiers).count : identifiers.count
    }

    /// Refuses, dry run included, a call over a range wider than `previousCutDays` that would make
    /// more than `maxDeletionOccurrences` deletions, before anything is deleted.
    static func checkDeletionSize(operations: Int, searched: Span) throws {
        guard widensPreviousCut(searched), operations > maxDeletionOccurrences else { return }
        throw RangeError.tooManyToDelete(count: operations, from: searched.start, to: searched.end)
    }

    /// The most duplicate comparisons over `searched`: limited only where the range is wider than
    /// the old cut.
    static func comparisonLimit(searched: Span) -> Int? {
        widensPreviousCut(searched) ? maxDuplicateComparisons : nil
    }

    /// The local form the responses use (`searched_from`, `searched_to`, the `*_local` fields), so
    /// a refusal and those fields state the same range.
    static func localText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
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

/// #325 verify rounds 3-4: which listed occurrences a span "future" delete already removed.
///
/// Removing an occurrence with `.futureEvents` removes its series from that occurrence's slot on.
/// A later listed occurrence of the same series is then skipped without an EventKit lookup. A
/// removal is recorded only when the occurrence removed is the one requested (`findOccurrence`
/// matches by day, and on a series with two occurrences that day can return the later one), and
/// it covers from the removed occurrence's slot (its `occurrenceDate`), which differs from its
/// start when it was moved. A later item is compared by its own slot too. Anything not covered,
/// or without a slot (the event_ids mode sends none), is tried as before.
struct FutureDeletionCoverage {
    private var coveredFrom: [String: Date] = [:]

    /// `slot` is the item's own slot (`EKEvent.occurrenceDate`); without one the item is tried.
    func covers(identifier: String, slot: Date?) -> Bool {
        // An occurrence edited on its own reads back as `<series>/RID=<slot>` (iCloud): its series
        // removal reaches it by its slot (device, 2026-10-20: it was reported "Event not found").
        if let rid = identifier.range(of: "/RID=", options: .backwards),
           let from = coveredFrom[String(identifier[..<rid.lowerBound])] {
            guard let slot = UndoPostState.originalSlot(eventIdentifier: identifier, externalIdentifier: nil,
                                                        occurrenceDate: nil) else { return false }
            return slot >= from
        }
        // By slot, not start (verify round 5): an occurrence whose slot is before the cut but
        // which was moved past it is not removed by the cut.
        guard let slot, let from = coveredFrom[identifier] else { return false }
        return slot >= from
    }

    mutating func recordRemoval(identifier: String, requested: Date?, removedStart: Date, removedSlot: Date?) {
        guard let requested, requested == removedStart else { return }
        let slot = removedSlot ?? removedStart
        coveredFrom[identifier] = min(coveredFrom[identifier] ?? slot, slot)
    }
}

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
