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

    /// #332 (PR #430 verify): the longest range that still counts as narrow, a day past the cut. A
    /// range is measured in elapsed time and given in wall-clock dates, so four calendar years
    /// across a clock change are 1461 days and an hour: the default search (`defaultSearchRange`)
    /// and a caller's four-year range must not fall under the wide rules for that hour.
    static let wideRangeDays = previousCutDays + 1

    /// The most deletions one `delete_events_batch` by date range may make over a range wider than
    /// `wideRangeDays` (verify rounds 1-2). Those ranges reach more than they did before #325:
    /// a one-sided range now reaches 100 years, and an open-ended daily series alone is about 36,500
    /// occurrences there, all in one `.batch` undo entry that restores each as a one-off event. A
    /// narrower range is not limited by it. A one-sided range is always
    /// wider (it reaches 100 years), so it is always under this limit (verify round 3, maintainer's
    /// choice): before #325 the same call deleted only the first four years, silently. Counted as
    /// deletions, not occurrences: span "all" and span "future" delete each series once.
    static let maxDeletionOccurrences = 2000

    /// The most candidate comparisons one `find_duplicate_events` may make over a range wider than
    /// `wideRangeDays` (verify round 3). Two calendars holding the same daily series, with a
    /// tolerance covering the range, pair every occurrence with every other: 1461² ≈ 2.1 million
    /// over the old four-year cut, about 1.3 billion over 100 years, held in memory and sorted on
    /// the manager's actor. This limit is about the old worst case; a narrower range is not limited.
    static let maxDuplicateComparisons = 2_000_000

    /// #332: the most event occurrences one range read may gather over a range wider than
    /// `wideRangeDays`; past it the read stops with `RangeError.tooManyEvents`. A safety valve against
    /// an abnormal calendar, not an everyday limit, and a default the maintainer may change: reading
    /// is cheap (measured 2026-11-05 on throwaway calendars, no user calendar: 218,949 occurrences in
    /// about 4.1 s of CPU and 276 MB), and 20,000 refused ordinary calls, such as a one-sided span all delete on a
    /// calendar with four weekly series (PR #430 verify). It is about 2,000 occurrences a year over
    /// 100 years, 500 a year over the 400-year ceiling. A narrower range is not limited. Checked after
    /// each span, and a span is one EventKit call that is read whole, so a read can pass this by
    /// that span's size, which has no fixed limit.
    static let maxEventsRead = 200_000

    /// #332: the rows `list_events` / `search_events` return over a range wider than
    /// `wideRangeDays` when the caller gives no `limit`. A default the maintainer may change.
    /// Formatting, not reading, is most of a wide answer's cost (measured before the read bound:
    /// 17.4 s and 48.5 MB of JSON for all 72,983 rows).
    static let defaultWideOutput = 500

    /// #332: which tool a read-bound refusal speaks to: each has a different way out.
    enum ReadPath: Equatable {
        case listing
        /// `delete_events_batch` by date range always names a calendar and has no `limit`.
        case deletion
        /// `find_duplicate_events` only compares different calendars, so one calendar is no way out:
        /// such a call is refused (#437).
        case duplicates
        /// `check_conflicts` has no `limit`, and one calendar answers for that calendar only.
        case conflicts
    }

    enum RangeError: LocalizedError, Equatable {
        case tooWide(days: Int)
        case tooManyToDelete(count: Int, from: Date, to: Date)
        case tooManyComparisons(limit: Int)
        /// #332: the read passed `maxEventsRead` over a wide range; `readThrough` is the end of the
        /// last span read. `collect` does not know its tool: see `worded(_:for:)`.
        case tooManyEvents(limit: Int, from: Date, to: Date, readThrough: Date, path: ReadPath = .listing)

        var errorDescription: String? {
            switch self {
            case .tooWide(let days):
                let ceiling = Self.grouped(EventRangeQuery.maxSpans * EventRangeQuery.maxSpanDays)
                return "Date range too wide: \(days) days. At most \(ceiling) days (about 400 years; \(EventRangeQuery.maxSpans) queries of \(EventRangeQuery.maxSpanDays) days) can be searched in one call; narrow the range."
            case .tooManyToDelete(let count, let from, let to):
                return "Refusing to delete: from \(EventRangeQuery.localText(from)) to \(EventRangeQuery.localText(to)) this call would make \(count) deletions, more than the \(EventRangeQuery.maxDeletionOccurrences) allowed for a range wider than \(EventRangeQuery.wideRangeDays) days. Nothing was deleted. Give both after_date and before_date, at most \(EventRangeQuery.previousCutDays - 1) days apart."
            case .tooManyEvents(let limit, let from, let to, let readThrough, let path):
                let stopped = "Stopped: from \(EventRangeQuery.localText(from)) to \(EventRangeQuery.localText(to)) holds more than \(Self.grouped(limit)) event occurrences, the most a range wider than \(EventRangeQuery.wideRangeDays) days reads (read through \(EventRangeQuery.localText(readThrough)); the count is checked after each \(EventRangeQuery.maxSpanDays)-day part, which is read whole, so a read can pass it by that part's size)."
                switch path {
                case .listing:
                    return "\(stopped) Nothing was returned. Narrow the range, or, if no calendar was named, read one with calendar_name. A limit does not lift this bound."
                case .deletion:
                    return "\(stopped) Nothing was deleted. Give both after_date and before_date, at most \(EventRangeQuery.previousCutDays - 1) days apart."
                case .duplicates:
                    return "\(stopped) Nothing was returned. Narrow the range. Naming fewer calendars in calendar_names also reads less: keep at least two, since only events in different calendars are compared."
                case .conflicts:
                    return "\(stopped) Nothing was returned. Narrow the range, or, if no calendar was named, give calendar_name; other calendars are then not checked."
                }
            case .tooManyComparisons(let limit):
                return "Stopped: finding duplicates over a range wider than \(EventRangeQuery.wideRangeDays) days took more than \(Self.grouped(limit)) comparisons. Nothing was returned. Narrow the range or lower tolerance_minutes."
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
        // #332: only a wide range is bounded (`wideRangeDays`; nothing changes below it).
        let bound = widensPreviousCut(Span(start: start, end: end)) ? maxEventsRead : nil
        for span in try spans(from: start, to: end) {
            let from = span.start > start ? max(start, span.start.addingTimeInterval(-1)) : span.start
            for item in query(from, span.end) where seen.insert(key(item)).inserted {
                found.append(item)
            }
            if let bound, found.count > bound {
                throw RangeError.tooManyEvents(limit: bound, from: start, to: end, readThrough: span.end)
            }
        }
        return found
    }

    /// #332: a read-bound refusal worded for the tool that made the read; any other error as it is.
    static func worded(_ error: Error, for path: ReadPath) -> Error {
        guard case .tooManyEvents(let limit, let from, let to, let readThrough, _)? = error as? RangeError else { return error }
        return RangeError.tooManyEvents(limit: limit, from: from, to: to, readThrough: readThrough, path: path)
    }

    /// #332: the rows `list_events` returns: the first `requested` when the caller gave a `limit`;
    /// otherwise the first `defaultWideOutput` over a range wider than `wideRangeDays`, and all of
    /// them below. `defaultLimit` is set only when the default left some out.
    static func bounded<Item>(_ items: [Item], requested: Int?, searched: Span) -> (rows: [Item], defaultLimit: Int?) {
        if let requested { return (Array(items.prefix(requested)), nil) }
        guard widensPreviousCut(searched), items.count > defaultWideOutput else { return (items, nil) }
        return (Array(items.prefix(defaultWideOutput)), defaultWideOutput)
    }

    /// #332: the rows `search_events` returns. It has no sort, and its read order holds spans in
    /// order but is not date order (PR #430 verify round 2: 40 of the first 500 rows were among the
    /// oldest 500), so a prefix would be an arbitrary set. One rule for any cut, a caller's `limit`
    /// or the default, on any range: the rows closest to `now`, then in start order, ties in read
    /// order both times. Nothing cut: as read. `defaultLimit` as in `bounded`.
    static func boundedNearNow<Item>(_ items: [Item], requested: Int?, searched: Span, now: Date,
                                     start: (Item) -> Date) -> (rows: [Item], defaultLimit: Int?) {
        guard let keep = requested ?? (widensPreviousCut(searched) ? defaultWideOutput : nil), items.count > keep else {
            return (items, nil)
        }
        let timed = items.enumerated().map { (offset: $0.offset, element: $0.element, start: start($0.element)) }
        let nearest = timed.sorted {
            (abs($0.start.timeIntervalSince(now)), $0.offset) < (abs($1.start.timeIntervalSince(now)), $1.offset)
        }.prefix(keep)
        return (nearest.sorted { ($0.start, $0.offset) < ($1.start, $1.offset) }.map(\.element),
                requested == nil ? keep : nil)
    }

    /// #332: what a `search_events` answer says about any cut.
    static func nearestNote(kept: Int, total: Int) -> String {
        "These are the \(kept) of \(total) matches closest to today, sorted by start. For the others give a narrower range, or a larger limit (at most \(InputValidation.maxLimit))."
    }

    /// #332: what `search_events` and `findSimilarEvents` search when not told: two Gregorian years
    /// either side of `now`, in `zone`. Gregorian whatever the host chose in region settings: a
    /// Hebrew or Chinese year is not one, which made this up to 17 days over the wide line. Across a
    /// clock change it is 1461 days and an hour, so it stays narrow (`wideRangeDays`).
    static func defaultSearchRange(now: Date, zone: TimeZone = .current) -> Span {
        let gregorian = Calendar.gregorian(in: zone)
        return Span(start: gregorian.date(byAdding: .year, value: -2, to: now) ?? now,
                    end: gregorian.date(byAdding: .year, value: 2, to: now) ?? now)
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

    /// Whether `range` is wider than EventKit's old cut, i.e. one #325 widened, by more than the
    /// day of slack in `wideRangeDays`.
    static func widensPreviousCut(_ range: Span) -> Bool {
        range.end.timeIntervalSince(range.start) > TimeInterval(wideRangeDays) * 86_400
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

    /// #427 cluster verify: by date range with span "all", the row of an occurrence edited on its own
    /// (`<series>/RID=…`) whose series' own identifier is listed too is left to that series' row,
    /// which deletes the whole series, the occurrence included, as before #427. Judged on its own,
    /// that row was refused whenever the scan could not show the series ends (an open-ended one),
    /// while the series' row deleted it anyway. Only for a series whose own row deletes on its own
    /// (`seriesRowsThatDelete`, previewed first, cluster verify r2): when it is refused alone, as
    /// with a first occurrence moved past the next slot, the occurrence's row is kept and runs
    /// first, as on main, and the series' row then reaches the rest. An identifier without
    /// `/RID=` names no series and keeps its row.
    static func rowsTheSeriesRowDoesNotTake(_ items: [DeletionItem], seriesRowsThatDelete: Set<String>) -> [DeletionItem] {
        items.filter { item in
            DetachedOccurrenceSpan.seriesIdentifier(of: item.identifier).map { !seriesRowsThatDelete.contains($0) } ?? true
        }
    }

    /// The series whose own identifier is listed beside an occurrence of theirs with `/RID=`: the
    /// ones to preview before `rowsTheSeriesRowDoesNotTake`.
    static func seriesListedWithTheirOccurrences(_ items: [DeletionItem]) -> Set<String> {
        let listed = Set(items.map(\.identifier))
        return Set(items.compactMap { DetachedOccurrenceSpan.seriesIdentifier(of: $0.identifier) }.filter { listed.contains($0) })
    }

    /// The deletions these items make, at most: span "all" deletes each series once, whole, and
    /// span "future" each series once from its earliest listed slot. An occurrence edited on its
    /// own that has its own identifier (`<series>/RID=…` on iCloud) counts as one more, even when
    /// its series' removal then takes it (it is reported as already_removed). With span "all" the
    /// rows a listed series' row takes are dropped before this count (`rowsTheSeriesRowDoesNotTake`).
    static func deletionOperations(_ identifiers: [String], span: String) -> Int {
        span == "all" || span == "future" ? Set(identifiers).count : identifiers.count
    }

    /// Refuses, dry run included, a call over a range wider than `wideRangeDays` that would make
    /// more than `maxDeletionOccurrences` deletions, before anything is deleted.
    static func checkDeletionSize(operations: Int, searched: Span) throws {
        guard widensPreviousCut(searched), operations > maxDeletionOccurrences else { return }
        throw RangeError.tooManyToDelete(count: operations, from: searched.start, to: searched.end)
    }

    /// The most duplicate comparisons over `searched`: limited only over a wide range.
    static func comparisonLimit(searched: Span) -> Int? {
        widensPreviousCut(searched) ? maxDuplicateComparisons : nil
    }

    /// The local form the responses use (`searched_from`, `searched_to`, the `*_local` fields), so
    /// a refusal and those fields state the same range. Gregorian with ASCII digits whatever the
    /// host locale (#304).
    static func localText(_ date: Date) -> String {
        DateFormatter.machineReadable("yyyy-MM-dd'T'HH:mm:ss", zone: TimeZone.current).string(from: date)
    }

    /// The most dry-run preview rows over `searched`: bounded only over a wide range (a span "all" call within the deletion ceiling can still list many occurrences).
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

/// #325 verify rounds 3-7: which listed occurrences a span "future" delete already removed.
///
/// Removing an occurrence with `.futureEvents` removes its series from that occurrence's slot on.
/// A later listed occurrence of the same series is then skipped without an EventKit lookup. With
/// a slot the occurrence is located exactly (`isRequested`), and a removal is recorded only when
/// the start and the slot are the requested ones; it covers from the removed occurrence's slot
/// (its `occurrenceDate`), which differs from its start when it was moved, and a later item is
/// compared by its own slot. An occurrence edited on its own (`<series>/RID=<slot>`) is judged
/// by the slot in its identifier, both when it is removed and when it is skipped. The event_ids
/// mode passes no occurrence dates, so nothing is recorded and nothing is skipped there.
struct FutureDeletionCoverage {
    private var coveredFrom: [String: Date] = [:]

    /// Whether an enumerated event is the requested occurrence: the same series identifier and,
    /// when a slot is given, that slot (verify round 6: a day can hold two occurrences of one series).
    static func isRequested(eventIdentifier: String?, occurrenceDate: Date?, identifier: String, slot: Date?) -> Bool {
        eventIdentifier == identifier && (slot == nil || occurrenceDate == slot)
    }

    /// `slot` is the item's own slot (`EKEvent.occurrenceDate`); a plain item without one is tried.
    func covers(identifier: String, slot: Date?) -> Bool {
        // An occurrence edited on its own reads back as `<series>/RID=<slot>` (iCloud): its series
        // removal reaches it by its slot (device, 2026-10-20: it was reported "Event not found").
        if let rid = identifier.range(of: "/RID=", options: .backwards),
           let from = coveredFrom[String(identifier[..<rid.lowerBound])] {
            guard let ridSlot = UndoPostState.originalSlot(eventIdentifier: identifier, externalIdentifier: nil,
                                                           occurrenceDate: nil) else { return false }
            return ridSlot >= from
        }
        // By slot, not start (verify round 5): an occurrence whose slot is before the cut but
        // which was moved past it is not removed by the cut.
        guard let slot, let from = coveredFrom[identifier] else { return false }
        return slot >= from
    }

    /// Records a span future removal, only when it removed exactly the requested occurrence: the
    /// same start and, when the request named one, the same slot (verify round 6: two occurrences
    /// can share a start). An occurrence edited on its own (`<series>/RID=<slot>`) is recorded for
    /// its series from that slot: removing it with span future removes the series from there on
    /// (device, iCloud, 2026-10-20).
    mutating func recordRemoval(identifier: String, requested: Date?, requestedSlot: Date?,
                                removedStart: Date, removedSlot: Date?) {
        guard let requested, requested == removedStart else { return }
        // An identifier with `/RID=` names one occurrence by itself (verify round 7): no slot check.
        if let requestedSlot, requestedSlot != removedSlot, !identifier.contains("/RID=") { return }
        var key = identifier
        var slot = removedSlot ?? removedStart
        if let rid = identifier.range(of: "/RID=", options: .backwards) {
            guard let ridSlot = UndoPostState.originalSlot(eventIdentifier: identifier, externalIdentifier: nil,
                                                           occurrenceDate: nil) else { return }
            key = String(identifier[..<rid.lowerBound])
            slot = ridSlot
        }
        coveredFrom[key] = min(coveredFrom[key] ?? slot, slot)
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
