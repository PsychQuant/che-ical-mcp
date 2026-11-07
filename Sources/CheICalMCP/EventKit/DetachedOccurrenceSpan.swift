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
/// `update_event` with span `all` or `future` through such an identifier is an allowlist (PR #431
/// round 5): `allowedUpdateFields`, the fields measured field by field, and nothing else, so a new
/// parameter is refused until it is measured. What the measurements on weekly series of 5 showed,
/// comparing every occurrence's title, start, end, notes, location and alarms before and after:
///
/// - New `title`, `notes`, `location`: they reach the occurrences the span covers, and the
///   occurrence's other values stay on it. New `recurrence`: applied, no occurrence took this one's
///   title, notes or time.
/// - The same value as the occurrence holds: answered updated, and the others did not change. Only
///   what differs from the object is written through, which also explains `clear_recurrence`
///   (the object has no rules to clear) and the dates: `start_time` alone gave the others this
///   occurrence's length, `end_time` alone its time, `all_day` its weekday. So a repeated value is
///   refused (`sameValueReason`), and the rest are not allowed.
/// - A write that starts a new series from the occurrence (span `future` from a later one, span
///   `all` or `future` from the first left after the first was deleted) carries its own location
///   and alarms to the new series, even when only `title` was written; not its title, notes, time
///   or URL. The first occurrence, which starts no new series, carries nothing. So such a write is
///   refused while the occurrence holds values of its own (`OwnValues`), unless it writes `location`,
///   which replaces that one. Time zone, all-day and availability were not measured and count too.
/// - A new `days_of_week` is read from the occurrence's original day: from a first occurrence moved
///   to Wednesday, a rule on Wednesdays through its id left two occurrences on that day.
///
/// `occurrence_date` that is not this occurrence is refused with span `this` or `future`: it was
/// ignored, and the write started at the occurrence the id names.
///
/// Not refused:
/// - `update_event` span `future` with the allowed fields: it does what the span says, from this
///   occurrence on, and a split there is what the description says it does; `id_changed` reports it.
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
/// such a source reports as detached. On iCloud an occurrence past the scan, in a series that
/// reaches more than about five years from its start, gets `pastScanReason`, which names the
/// series' id: that route was run there, for an update and a delete.
///
/// The reasons are fixed strings: no EventKit text, no user input.
enum DetachedOccurrenceSpan {
    private static let slotMarker = "/RID="

    /// What a write that starts a new series from this occurrence would have to deal with.
    struct OwnValues: Equatable {
        /// The series' first slot is not this occurrence's: it was deleted, so even span `all`
        /// saves what remains as a new series (#326).
        var firstSlotGone = false
        /// A location or place other than the series' (carried, measured).
        var location = false
        /// Alarms (carried, measured), or a time zone, an all-day flag, availability or coordinates
        /// of its own (not measured).
        var other = false
    }

    /// What is left of the series around the occurrence. `nil` where one is taken means unknown.
    struct Neighbours: Equatable {
        /// An occurrence with an earlier slot: update span `all` would split the series. Exact: the
        /// scan starts at the series' start and holds this occurrence (`neighbours`).
        let earlierRemain: Bool
        /// Any other occurrence the call did not name, or a scan that cannot show there is none:
        /// delete span `all` would leave it.
        let othersRemain: Bool
        var own = OwnValues()

        /// Whether a save from this occurrence starts a new series.
        var startsNewSeries: Bool { earlierRemain || own.firstSlotGone }
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
                           coversWholeSeries: Bool, namedInTheCall: Set<String> = [], own: OwnValues = OwnValues()) -> Neighbours? {
        guard candidates.contains(where: { $0.eventIdentifier == identifier }) else { return nil }
        let others = candidates.filter { $0.eventIdentifier != identifier }
        let unnamed = others.filter { !namedInTheCall.contains($0.eventIdentifier ?? "") }
        return Neighbours(earlierRemain: others.contains { ($0.slot ?? $0.start) < slot },
                          othersRemain: !unnamed.isEmpty || !coversWholeSeries, own: own)
    }

    /// The refusal of `update_event` with span `all` or `future` through one occurrence, or nil
    /// when it goes ahead. `fields`: the keys of the call. `neighbours` is read only when the answer
    /// depends on it: it scans the series. Unknown comes first, as the other texts claim a series.
    static func updateRefusal(identifier: String, isDetached: Bool, wholeSeries: Bool, futureSpan: Bool = false,
                              fields: Set<String> = [], repeatsOccurrenceValue: Bool = false, writesLocation: Bool = false,
                              neighbours: @autoclosure () throws -> Neighbours?) rethrows -> String? {
        guard wholeSeries || futureSpan, addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return nil }
        guard let known = try neighbours() else {
            return unknownReason(identifier: identifier, span: wholeSeries ? "'all'" : "'future'", suffix: "Nothing was written.")
        }
        if !refusedUpdateFields(fields).isEmpty { return fieldsReason(wholeSeries: wholeSeries) }
        if wholeSeries && known.earlierRemain { return updateReason }
        if repeatsOccurrenceValue { return sameValueReason(wholeSeries: wholeSeries) }
        // With no other occurrence left there is nothing to carry to (measured: the only one left).
        let carried = known.startsNewSeries && known.othersRemain && carries(known.own, writesLocation: writesLocation)
        return carried ? carriedReason(wholeSeries: wholeSeries) : nil
    }

    /// `writesLocation`: a location is really written, not only a key with a value that is no text,
    /// which leaves the occurrence's own location to be carried.
    private static func carries(_ own: OwnValues, writesLocation: Bool) -> Bool {
        own.other || (own.location && !writesLocation)
    }

    /// The fields `update_event` writes with span `all` or `future` through one occurrence: what was
    /// measured field by field. Everything else is refused, a parameter added later included. The
    /// list holds top-level keys only: what is inside `recurrence` is not classified. `days_of_week`
    /// of a weekly rule is checked against the original day; a monthly rule was not measured.
    static let allowedUpdateFields: Set<String> = ["title", "notes", "location", "recurrence"]

    /// The keys of `update_event` that say what to write to, and write nothing themselves.
    static let updateKeysThatWriteNothing: Set<String> = ["event_id", "span", "occurrence_date"]

    static func refusedUpdateFields(_ fields: Set<String>) -> Set<String> {
        fields.subtracting(allowedUpdateFields).subtracting(updateKeysThatWriteNothing)
    }

    /// Whether the call writes a value the occurrence already holds. EventKit writes through what
    /// differs from the object, so that value reaches no other occurrence (measured). nil and empty
    /// text are the same, as in `UndoPostState.differsFromSeries`.
    static func repeatsOccurrenceValue(title: String?, notes: String?, location: String?,
                                       occurrenceTitle: String?, occurrenceNotes: String?, occurrenceLocation: String?) -> Bool {
        func same(_ new: String?, _ held: String?) -> Bool { new.map { $0 == (held ?? "") } ?? false }
        return same(title, occurrenceTitle) || same(notes, occurrenceNotes) || same(location, occurrenceLocation)
    }

    /// An update resolved to an edited occurrence by `occurrence_date`, on a source where that
    /// occurrence keeps the series' identifier. iCloud cannot get here (`findOccurrence` needs the
    /// identifier, and an edited occurrence has its own), and no such source was measured: Exchange
    /// may be one (#320). The save would be the same as through the occurrence's own id, so the
    /// same checks run. Whether it starts a new series is not known there, so it counts as doing
    /// so; `own` nil, nothing to compare with, counts as holding values of its own.
    static func resolvedOccurrenceRefusal(addressedByItsOwnId: Bool, resolvedIsDetached: Bool, futureSpan: Bool, fields: Set<String>,
                                          repeatsOccurrenceValue: Bool, writesLocation: Bool,
                                          own: @autoclosure () -> OwnValues?) -> String? {
        guard !addressedByItsOwnId, resolvedIsDetached, futureSpan else { return nil }
        if !refusedUpdateFields(fields).isEmpty { return fieldsReason(wholeSeries: false) }
        if repeatsOccurrenceValue { return sameValueReason(wholeSeries: false) }
        guard let known = own(), !carries(known, writesLocation: writesLocation) else { return carriedReason(wholeSeries: false) }
        return nil
    }

    /// The day a new `days_of_week` is read against through one occurrence: its original one, as
    /// the rule runs from there. nil elsewhere, where the planned or shown start is read.
    static func originalDay(identifier: String, isDetached: Bool, wholeSeries: Bool, futureSpan: Bool,
                            externalIdentifier: String?, occurrenceDate: Date?, isAllDay: Bool, zone: TimeZone = .current) -> Date? {
        guard wholeSeries || futureSpan, addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return nil }
        return UndoPostState.ruleSlot(eventIdentifier: identifier, externalIdentifier: externalIdentifier,
                                      occurrenceDate: occurrenceDate, isAllDay: isAllDay, zone: zone)
    }

    /// The refusal of `delete_event` / `delete_events_batch` with span `all` through one occurrence:
    /// with another one left, or with nothing known about the rest of the series.
    static func seriesDeleteRefusal(identifier: String, isDetached: Bool, batch: Bool,
                                    neighbours: @autoclosure () throws -> Neighbours?) rethrows -> String? {
        guard addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return nil }
        guard let known = try neighbours() else {
            return unknownReason(identifier: identifier, span: "'all'", suffix: batch ? "This row deleted nothing." : "Nothing was deleted.", deleting: true)
        }
        guard known.othersRemain else { return nil }
        return batch ? seriesDeleteBatchReason : seriesDeleteReason
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

    static let updateReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would split the series here: the earlier occurrences would stay in the old series, not updated. To update the whole series, use \(firstOccurrenceRoute) with span 'all'. If that is refused, \(noTestedWay). To update from this occurrence on, use span 'future', which ends the series here and starts a new one with a new identifier. To edit one occurrence, use span 'this'. Nothing was written."

    private static let seriesDeleteRoute = "To delete the whole series, use \(firstOccurrenceRoute), with span 'all' when that id has no /RID=… part and span 'future' when it has one (a delete with span 'future' from an edited occurrence cannot be undone). To delete this occurrence only, use span 'this'."

    static let seriesDeleteReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only this occurrence, not the series. \(seriesDeleteRoute) Nothing was deleted."

    /// `seriesDeleteReason` as a `delete_events_batch` row: the other rows may have been deleted.
    static let seriesDeleteBatchReason = "This identifier names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only this occurrence, not the series. \(seriesDeleteRoute) This row deleted nothing."

    /// Nothing is known about what the span would do. With no `/RID=` the routes of the other
    /// reasons would loop, as the first occurrence's id looks the same. With one, the occurrence
    /// lies past the scan, and the series' id is known: `pastScanReason`.
    static func unknownReason(identifier: String, span: String, suffix: String, deleting: Bool = false) -> String {
        if seriesIdentifier(of: identifier) != nil { return pastScanReason(span: span, suffix: suffix, deleting: deleting) }
        return "This identifier is reported as one occurrence edited on its own, and the rest of its series cannot be listed from it, so span \(span) cannot be shown to do what it says. Use span 'this' on this occurrence, which also does what span \(span) would if this is a single event reported wrongly. \(suffix)"
    }

    /// Run on a weekly series started about seven years ago, the occurrence edited this year: the
    /// series' id with span `all` took a location and a start and deleted the series.
    static func pastScanReason(span: String, suffix: String, deleting: Bool = false) -> String {
        let way = deleting ? seriesDeleteRoute
            : "Use the id list_events shows for an occurrence that was not edited on its own, with span 'all', for the whole series. If that is refused, \(noTestedWay)."
        return "This identifier names one occurrence of a recurring series, edited on its own, and it lies past what can be listed of the series, about five years from its start, so span \(span) cannot be shown to do what it says. \(way) \(suffix)"
    }

    /// The end of every update route: the series' id is refused with the first occurrence edited at
    /// its original start, or deleted with the first left edited (`FirstRemainingOccurrence.pick`).
    /// It says no more than that on purpose. Each longer version was false for some field: span
    /// `this` does not take `recurrence` or `clear_recurrence` there, and `move_events_batch` takes
    /// a calendar.
    private static let noTestedWay = "this shape has no tested way yet (#428)"

    /// The way around every refusal of `update_event` below, as run on a device: with span `all` the
    /// series' id took `start_time`, `end_time`, `timezone`, `url`, alarms, `structured_location`,
    /// `clear_recurrence`, `calendar_name` of the same account, and a value the occurrence holds,
    /// with an edited occurrence present; with span `future` from the next occurrence it took the
    /// same except `clear_recurrence`, `calendar_name` and `all_day` (#451). Span `this` on each
    /// occurrence works through either id. `all_day` adds an occurrence (#442), `clear_timezone`
    /// drops the last occurrence of a series with a count (#455), and a calendar of another account
    /// was not run.
    private static func otherRoute(wholeSeries: Bool) -> String {
        if wholeSeries {
            return "Use the id list_events shows for an occurrence that was not edited on its own, with span 'all'. Occurrences edited on their own keep what was edited, so they may need span 'this' after that. If that id is refused, \(noTestedWay)."
        }
        return "Use span 'this' on this occurrence, and for the later ones the id list_events shows for the next occurrence that was not edited on its own, with its occurrence_date and span 'future'. If that id is refused, \(noTestedWay)."
    }

    private static func opening(_ wholeSeries: Bool) -> String {
        "event_id names one occurrence of a recurring series, edited on its own, and with span \(wholeSeries ? "'all'" : "'future'") through it"
    }

    /// Everything but `allowedUpdateFields`.
    static func fieldsReason(wholeSeries: Bool) -> String {
        let limits = wholeSeries
            ? "That id leaves out all_day, which brings an edited occurrence's original slot back as an extra occurrence, clear_timezone, which drops the last occurrence of a series with a count, and a calendar of another account, which was not tried; clear_recurrence there leaves one event at the series' first date, without the edited occurrences. For a calendar of the same account, move_events_batch with span 'all' moves the whole series."
            : "That way leaves out all_day, clear_recurrence and calendar_name, which do not stay within the later occurrences, and clear_timezone, which was not tried."
        return "\(opening(wholeSeries)) only title, notes, location and recurrence can be written; any other field is refused, even one that changes nothing. Leave the others out. To write them: \(otherRoute(wholeSeries: wholeSeries)) \(limits) Nothing was written."
    }

    /// A value the occurrence already holds would answer updated and reach no other occurrence.
    static func sameValueReason(wholeSeries: Bool) -> String {
        "\(opening(wholeSeries)) a title, notes or location equal to what this occurrence already holds reaches no other occurrence, though the call would answer updated. Leave that field out if it is not meant to change. Otherwise: \(otherRoute(wholeSeries: wholeSeries)) Nothing was written."
    }

    /// A new series started from the occurrence takes its own location and alarms.
    static func carriedReason(wholeSeries: Bool) -> String {
        "\(opening(wholeSeries)) this call would start a new series from this occurrence, and that series would take values this occurrence holds on its own, such as its location or alarms. \(otherRoute(wholeSeries: wholeSeries)) Nothing was written."
    }

    /// A rule's day against the occurrence's original day, not the day it shows: through its id the
    /// new rule runs from the original one, and a rule on the shown day left two occurrences there.
    static let recurrenceDayReason = "event_id names one occurrence of a recurring series, edited on its own, and days_of_week does not hold the day of the week of its original date, the day the series runs from. Add that day, or leave days_of_week out. Nothing was written."

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
