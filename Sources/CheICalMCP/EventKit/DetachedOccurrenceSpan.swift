import EventKit

/// #416: writes that take a span, addressed through the identifier of an occurrence that was edited
/// on its own. That identifier resolves to the occurrence object (`isDetached`; on iCloud
/// `<series>/RID=<seconds>`), which has no recurrence rules of its own. Measured on device (iCloud,
/// 2026-11-05, throwaway calendars) against `main` without these refusals, with a weekly series of 5:
///
/// | Occurrence (its own id) | `update_event` span `all` | `delete_event` / batch span `all` |
/// |---|---|---|
/// | middle, earlier ones remain | split; only it and the later ones updated | only it deleted, answered "all" |
/// | first | every occurrence updated, id kept | only it deleted, answered "all" |
/// | first left, first one deleted | every remaining one updated, new id | only it deleted, answered "all" |
/// | the only one left | it updated, new id | it deleted |
///
/// Refused, before anything is written, is what did something other than what the caller asked for:
/// update span `all` with an earlier occurrence left, delete span `all` with any other occurrence
/// left. These are the coordinator's defaults while the maintainer has not answered.
///
/// Also refused (PR #431 round 2): through such an identifier with span `all` or `future`,
/// `clear_recurrence` (it answered updated and changed nothing, measured) and a calendar of another
/// account (not measured, and only shown safe within one account), and with span `this` or `future`
/// an `occurrence_date` that is not this occurrence (it was ignored, and the write started at the
/// occurrence the id names, measured). A new `recurrence` is not refused: with span `all` from the
/// first occurrence and from the first left, and with span `future` from a middle one, it did what
/// it says (measured).
///
/// What is written through such an identifier was measured field by field, on weekly series of 5,
/// comparing every occurrence's title, start, end and notes before and after:
///
/// - Only `location` (round 3): the occurrence's title and notes, time (+2h) or weekday stayed on
///   it, and the others kept theirs, with span `all` from the first occurrence, from the first left
///   and with the fourth edited too, and with span `future` from a middle one.
/// - Dates (round 4, 2026-11-06), refused: `start_time` alone gave the others this occurrence's
///   length (10:00–13:00 here, then 09:00 written: every one 09:00–12:00, not 09:00–10:00), span
///   `all` and `future`; `end_time` alone gave them its time; `all_day` moved them to its weekday,
///   span `all` and `future`. `start_time` from an occurrence moved by +2h, with the series' length,
///   did what was asked, and is refused all the same: the class is refused, not the shape, as it
///   only works while the occurrence still holds the series' values, which nothing here reads.
///   `timezone` is in the class; it was run once for each span and not judged on its own. A single
///   occurrence left is refused too; span `this` does the same there.
/// - A new `recurrence` (round 4): no occurrence took this one's title, notes or time, from the
///   first occurrence (+2h, or moved to another weekday, weekly and daily and every 2 weeks), from
///   the first left, and with span `future` from a middle one. Not refused. An `occurrence_count`
///   with span `future` counts from the series' start, through the series' id too (count 6 from the
///   third occurrence gave 4 weekly); that is not this path's.
///
/// Not refused:
/// - `update_event` span `future` without dates: it does what the span says, from this occurrence
///   on, and a split there is what the description says it does; `id_changed` reports it.
/// - span `this`, and `delete_event` span `future` (this occurrence and the later ones; from the
///   first occurrence, the whole series).
/// - `move_events_batch` span `all`: all occurrences moved and the identifier stayed, within one
///   iCloud account. Across accounts was not measured.
/// - `delete_events_batch` by date range: the listing named the identifier, not the caller; a range
///   holding only that occurrence deletes it alone (#427).
///
/// Sources: `/RID=` and `isDetached` were measured reliable on Google (#320), and these refusals ran
/// on iCloud only. On a source with no `/RID=`, which Exchange may be (not measured), the rest of the
/// series cannot be listed, so span `all` is refused with `unknownReason`, also for a one-off that
/// such a source reports as detached. On iCloud the same text answers for an occurrence past the
/// scan, in a series that reaches more than about five years from its start.
///
/// The reasons are fixed strings: no EventKit text, no user input.
enum DetachedOccurrenceSpan {
    private static let slotMarker = "/RID="

    /// What is left of the series around the occurrence. `nil` where one is taken means unknown.
    struct Neighbours: Equatable {
        /// An occurrence with an earlier slot: update span `all` would split the series. Exact: the
        /// scan starts at the series' start and holds this occurrence (`neighbours`).
        let earlierRemain: Bool
        /// Any other occurrence the call did not name, or a scan that cannot show there is none:
        /// delete span `all` would leave it.
        let othersRemain: Bool
    }

    /// What a rule says about how far the series reaches.
    struct RuleExtent: Equatable {
        let endDate: Date?
        let occurrenceCount: Int
        let frequency: EKRecurrenceFrequency
        let interval: Int
        /// A filter that can leave a period with no occurrence: the 31st, January only, the 5th
        /// occurrence of a weekday in a month.
        let hasFilter: Bool
        /// Days of the week: a filter on a daily, monthly or yearly rule, but not on a weekly one,
        /// where every week holds them.
        let hasDaysOfTheWeek: Bool

        init(_ rule: EKRecurrenceRule) {
            endDate = rule.recurrenceEnd?.endDate
            occurrenceCount = rule.recurrenceEnd?.occurrenceCount ?? 0
            frequency = rule.frequency
            interval = rule.interval
            hasFilter = rule.daysOfTheMonth != nil || rule.daysOfTheYear != nil || rule.weeksOfTheYear != nil
                || rule.monthsOfTheYear != nil || rule.setPositions != nil
            hasDaysOfTheWeek = rule.daysOfTheWeek != nil
        }
    }

    /// The identifier names one occurrence: the object is detached, or the identifier carries a
    /// `/RID=` slot. `/RID=` was measured reliable on Google (#320); Exchange was not measured and
    /// may give none, so the object's `isDetached` is read too.
    static func addressesOneOccurrence(identifier: String, isDetached: Bool) -> Bool {
        isDetached || identifier.contains(slotMarker)
    }

    /// The part of an occurrence's identifier before `/RID=`; nil without one, as nothing says what
    /// the series' identifier is then.
    static func seriesIdentifier(of identifier: String) -> String? {
        guard let range = identifier.range(of: slotMarker), range.lowerBound != identifier.startIndex else { return nil }
        return String(identifier[..<range.lowerBound])
    }

    /// The latest a rule can reach, or nil when that cannot be shown. With a count, each period
    /// holds at least one occurrence only without a filter, and a monthly or yearly rule also needs
    /// to start by the 28th, as later days skip short months. `calendar` is in the event's zone,
    /// where the rule runs: a Feb 29 read in another zone can show Feb 28.
    static func lastPossibleSlot(of rule: RuleExtent, firstStart: Date, calendar: Calendar) -> Date? {
        if let end = rule.endDate { return end }
        guard rule.occurrenceCount > 0, !rule.hasFilter else { return nil }
        let periods = rule.occurrenceCount * rule.interval
        switch rule.frequency {
        case .daily:
            return rule.hasDaysOfTheWeek ? nil : calendar.date(byAdding: .day, value: periods, to: firstStart)
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * periods, to: firstStart)
        case .monthly, .yearly:
            guard !rule.hasDaysOfTheWeek, calendar.component(.day, from: firstStart) <= 28 else { return nil }
            return calendar.date(byAdding: rule.frequency == .monthly ? .month : .year, value: periods, to: firstStart)
        @unknown default:
            return nil
        }
    }

    /// Whether a scan up to `scannedTo` can have listed every slot of the series. The scan is
    /// bounded (`UndoPostState.seriesScanWindow`), so listing nothing else shows nothing by itself.
    /// An occurrence edited to a time more than a year past the scan is not seen, as everywhere the
    /// scan is used.
    static func coversWholeSeries(rules: [RuleExtent], firstStart: Date, scannedTo: Date, calendar: Calendar) -> Bool {
        !rules.isEmpty && rules.allSatisfy { rule in
            lastPossibleSlot(of: rule, firstStart: firstStart, calendar: calendar).map { $0 <= scannedTo } ?? false
        }
    }

    /// `candidates` are the series' listed occurrences (`FirstRemainingOccurrence.Candidate`). By
    /// slot, not by the time it shows: a write with `.futureEvents` covers slots. nil when the
    /// occurrence itself is not among them: it lies past the scan, so the list says nothing about
    /// what is around it. `namedInTheCall`: identifiers the same `event_ids` call also deletes,
    /// which do not count as left behind.
    static func neighbours(of identifier: String, slot: Date, among candidates: [FirstRemainingOccurrence.Candidate],
                           coversWholeSeries: Bool, namedInTheCall: Set<String> = []) -> Neighbours? {
        guard candidates.contains(where: { $0.eventIdentifier == identifier }) else { return nil }
        let others = candidates.filter { $0.eventIdentifier != identifier }
        let unnamed = others.filter { !namedInTheCall.contains($0.eventIdentifier ?? "") }
        return Neighbours(earlierRemain: others.contains { ($0.slot ?? $0.start) < slot },
                          othersRemain: !unnamed.isEmpty || !coversWholeSeries)
    }

    /// The refusal of `update_event` through one occurrence. With span `all`: with an earlier one
    /// left, with nothing known about the rest of the series, or for a date. With span `future`:
    /// for a date. nil when it goes ahead. `neighbours` is read only when the answer depends on it:
    /// it scans the series. Unknown comes before dates, as `dateReason` claims a series.
    static func updateRefusal(identifier: String, isDetached: Bool, wholeSeries: Bool, futureSpan: Bool = false,
                              changesDates: Bool = false, neighbours: @autoclosure () -> Neighbours?) -> String? {
        guard addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return nil }
        guard wholeSeries else { return futureSpan && changesDates ? dateReason(wholeSeries: false) : nil }
        guard let known = neighbours() else { return unknownReason(suffix: "Nothing was written.") }
        if changesDates { return dateReason(wholeSeries: true) }
        return known.earlierRemain ? updateReason : nil
    }

    /// The refusal of `delete_event` / `delete_events_batch` with span `all` through one occurrence:
    /// with another one left, or with nothing known about the rest of the series.
    static func seriesDeleteRefusal(identifier: String, isDetached: Bool, batch: Bool,
                                    neighbours: @autoclosure () -> Neighbours?) -> String? {
        guard addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return nil }
        guard let known = neighbours() else {
            return unknownReason(suffix: batch ? "This row deleted nothing." : "Nothing was deleted.")
        }
        guard known.othersRemain else { return nil }
        return batch ? seriesDeleteBatchReason : seriesDeleteReason
    }

    /// `clear_recurrence` or a calendar of another account through one occurrence, with span `all`
    /// or `future`.
    static func refusesSeriesProperty(identifier: String, isDetached: Bool, wholeSeries: Bool, span: EKSpan,
                                      changesAccount: Bool, clearsRecurrence: Bool) -> Bool {
        guard wholeSeries || span != .thisEvent else { return false }
        return (changesAccount || clearsRecurrence) && addressesOneOccurrence(identifier: identifier, isDetached: isDetached)
    }

    /// An `occurrence_date` that is not the occurrence the identifier names. Span `all` takes no
    /// occurrence.
    static func refusesOccurrenceDate(identifier: String, isDetached: Bool, wholeSeries: Bool, hasOccurrenceDate: Bool,
                                      matches: @autoclosure () -> Bool) -> Bool {
        guard !wholeSeries, hasOccurrenceDate, addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return false }
        return !matches()
    }

    /// The way to the whole series. It is not the series' identifier: that is refused when the first
    /// occurrence was edited on its own and still starts at its original time (#428). By the original date because the check compares
    /// slots and an edited occurrence can show another time. For a series whose first occurrence was
    /// deleted, an update takes this route only if the first occurrence left was edited on its own:
    /// unedited, the id resolves through the stand-in, which refuses a whole-series update (#326),
    /// measured. A delete takes it either way.
    private static let firstOccurrenceRoute = "the id list_events shows for the occurrence that comes first in the series (by its original date, not a time it was moved to)"

    static let updateReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would split the series here: the earlier occurrences would stay in the old series, not updated. To update the whole series, use \(firstOccurrenceRoute) with span 'all'. A series whose first occurrence was deleted takes that only if its first occurrence left was edited on its own too; otherwise a whole-series update is not supported (#326). To update from this occurrence on, use span 'future', which ends the series here and starts a new one with a new identifier. To edit one occurrence, use span 'this'. Nothing was written."

    private static let seriesDeleteRoute = "To delete the whole series, use \(firstOccurrenceRoute), with span 'all' when that id has no /RID=… part and span 'future' when it has one (a delete with span 'future' from an edited occurrence cannot be undone). To delete this occurrence only, use span 'this'."

    static let seriesDeleteReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only this occurrence, not the series. \(seriesDeleteRoute) Nothing was deleted."

    /// `seriesDeleteReason` as a `delete_events_batch` row: the other rows may have been deleted.
    static let seriesDeleteBatchReason = "This identifier names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only this occurrence, not the series. \(seriesDeleteRoute) This row deleted nothing."

    /// With no way to list the series, or an occurrence past the scan, nothing is known about what
    /// span `all` would do, and on a source with no `/RID=` the routes of the other reasons would
    /// loop: the first occurrence's id looks the same.
    static func unknownReason(suffix: String) -> String {
        "This identifier is reported as one occurrence edited on its own, and the rest of its series cannot be listed from it, so span 'all' cannot be shown to do what it says. Use span 'this' on this occurrence, which also does what span 'all' would if this is a single event reported wrongly. \(suffix)"
    }

    /// No route for span `future`: span `all` would reach earlier occurrences the caller did not ask
    /// for, and it cannot be undone.
    static func seriesPropertyReason(wholeSeries: Bool) -> String {
        let span = wholeSeries ? "'all'" : "'future'"
        let opening = "event_id names one occurrence of a recurring series, edited on its own, and span \(span) through it cannot take clear_recurrence or a calendar of another account: clear_recurrence through it would answer updated and change nothing, and a move to another account was not shown safe from an occurrence."
        let way = wholeSeries
            ? "To make either change, use the id list_events shows for an occurrence that was not edited on its own, with span 'all'; if that is refused too, the change is not supported on this series."
            : "Neither is supported from an occurrence edited on its own."
        return "\(opening) \(way) Nothing was written."
    }

    /// `start_time`, `end_time`, `all_day`, `timezone` through one occurrence (round 4). Each way
    /// named here was run on a device. The series' id with span `all` took a start with the first
    /// occurrence in place, and with the first occurrence edited and its start moved; it is refused
    /// with the first occurrence edited at its original start (#428) or deleted (#326), and with
    /// `all_day` it adds an occurrence (#442). Span `this` on each occurrence works through either
    /// id. No way was run for span `future`, so none is named.
    static func dateReason(wholeSeries: Bool) -> String {
        let span = wholeSeries ? "'all'" : "'future'"
        let others = wholeSeries ? "the other occurrences" : "the later occurrences"
        let opening = "event_id names one occurrence of a recurring series, edited on its own, and span \(span) through it cannot change start_time, end_time, all_day or timezone: \(others) would take this occurrence's own time, length or day."
        let way = wholeSeries
            ? "To change start_time, end_time or timezone for the whole series, use the id list_events shows for an occurrence that was not edited on its own, with span 'all'. If that is refused, or for all_day (through that id it brings an edited occurrence's original slot back as an extra occurrence), no single call changes the whole series: use span 'this' on each occurrence, with occurrence_date when the id list_events shows for it has no /RID=… part."
            : "This is not supported from an occurrence edited on its own. To change this occurrence alone, use span 'this'."
        return "\(opening) \(way) Nothing was written."
    }

    /// `event_ids` rows for a span `all` delete, each id once: occurrences' own ids first, earliest
    /// slot first, then the rest in the caller's order. A row's check counts the others in the call
    /// as deleted, so the result must not depend on the order: with the series' row first and the
    /// first occurrence edited, that row was refused and the occurrence's row then deleted it alone
    /// (measured, with a `Set`'s order).
    static func occurrenceRowsFirst(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        let unique = identifiers.filter { seen.insert($0).inserted }
        func slot(_ identifier: String) -> Int? {
            identifier.range(of: slotMarker).map { Int(identifier[$0.upperBound...]) ?? .max }
        }
        let occurrences = unique.enumerated().compactMap { index, id in slot(id).map { (index, id, $0) } }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }.map(\.1)
        return occurrences + unique.filter { slot($0) == nil }
    }

    static let occurrenceDateReason = "event_id names one occurrence, edited on its own, and occurrence_date is another day. To act on that other occurrence, use the id list_events shows for that occurrence, with its occurrence_date; to act on this one, leave occurrence_date out. Nothing was changed."
}
