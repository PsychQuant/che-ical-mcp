import EventKit
import Foundation

/// #532: a series' identifier and a day do not address an occurrence that was edited on its own.
///
/// Such an occurrence reads back with an identifier of its own (on iCloud and, through EventKit,
/// on Google: the series' identifier, `/RID=` and its slot), while `findOccurrence` takes an event
/// only under the exact identifier it was given. So `update_event`, `delete_event` and
/// `move_events_batch` answered "not found" for a day on which the calendar shows an occurrence,
/// and `create_event` read an excluded date that still holds one as already excluded (#534).
///
/// The lookup stays as it is. When it misses, the callers ask this type which occurrences edited
/// on their own belong to the requested day, and answer a refusal that gives each one's
/// identifier, writing nothing. An occurrence belongs to the day by either date, as
/// `occurrenceDateMatches` (#416) accepts either through the occurrence's own identifier:
/// - it starts on that day (edited in place, or moved onto it), or
/// - the slot the rule gave it is on that day and it now starts on another day.
///
/// Pure: events come in as `Reading` values and every zone is a parameter. `zone` is the zone the
/// requested day was read in (the event's, this Mac's for an event with none), `host` this Mac's
/// zone, in which all-day events are whole days (#364).
enum EditedOccurrenceAddress {
    /// What is read of one event: of each event of the requested day, and of each listed
    /// occurrence of the series.
    struct Reading: Equatable {
        let eventIdentifier: String?
        let externalIdentifier: String?
        let occurrenceDate: Date?
        let isDetached: Bool
        let isAllDay: Bool
        let start: Date?
    }

    enum Kind: Equatable {
        /// It starts on the requested day.
        case shownThatDay
        /// Its slot is on the requested day, and it starts on another day.
        case originallyThatDay
    }

    /// One occurrence edited on its own that belongs to the requested day.
    struct Match: Equatable {
        /// The identifier `list_events` shows for it.
        let identifier: String
        let start: Date
        let isAllDay: Bool
        let kind: Kind
        /// The day of the slot the rule gave it, `yyyy-MM-dd`; nil when no slot is known.
        let originalDay: String?
    }

    /// The call whose lookup missed. The texts differ: what to pass, and what a span `future` call
    /// through the occurrence's identifier does, are not the same for the three tools.
    enum Call: Equatable {
        case update(futureSpan: Bool)
        case delete(futureSpan: Bool)
        /// One row of `move_events_batch` (span `this`; span `all` takes no date).
        case moveRow
    }

    /// What a caller answers for a lookup that missed.
    enum Miss: Equatable {
        /// An edited occurrence belongs to the day: the reason, a trusted message.
        case refusal(String)
        /// None was found: the detail of the not-found error (#535).
        case notFound(detail: String)
    }

    // MARK: - Which occurrences belong to the day

    /// The occurrences of the series `seriesID` that were edited on their own and belong to the
    /// requested day, each once, in the order of their starts.
    ///
    /// - `day`: every event the requested day's window holds, of any series. One is taken when its
    ///   identifier is the series' identifier followed by `/RID=` (the exact series part, so a
    ///   longer identifier with the same first characters is not) and it starts on the day.
    /// - `series`: the listed occurrences of the series, already tied to it by either identifier
    ///   (`seriesOccurrences`), or nil when the series could not be listed. One is taken when it is
    ///   an occurrence edited on its own and starts on the day, or its slot is on the day. This is
    ///   the only way to one that was moved off the day, and to one a store ties to its series by
    ///   the external identifier alone. With nil, only the first list is read: nothing is named
    ///   that was not read (fail closed).
    ///
    /// An edited occurrence whose identifier is the series' own is not reported: the identifier
    /// would not address it (no such source was measured; the caller then answers not found).
    static func matches(onDay day: [Reading], listed series: [Reading]?, seriesID: String, seriesIsAllDay: Bool,
                        requested: Date, zone: TimeZone, host: TimeZone = .current) -> [Match] {
        func onTheDay(_ date: Date?, isAllDay: Bool) -> Bool {
            OccurrenceDay.startsOnRequestedDay(occurrenceStart: date, isAllDay: isAllDay, requested: requested, in: zone, host: host)
        }
        /// The slot the rule gave it; an all-day series' `/RID=` is a date, read in the host's zone.
        func slot(of reading: Reading) -> Date? {
            UndoPostState.ruleSlot(eventIdentifier: reading.eventIdentifier, externalIdentifier: reading.externalIdentifier,
                                   occurrenceDate: reading.occurrenceDate, isAllDay: seriesIsAllDay, zone: host)
        }
        func match(_ reading: Reading, identifier: String, start: Date, kind: Kind) -> Match {
            Match(identifier: identifier, start: start, isAllDay: reading.isAllDay, kind: kind,
                  originalDay: slot(of: reading).map { self.day($0, in: seriesIsAllDay ? host : zone) })
        }

        var found: [Match] = []
        var seen: Set<String> = []
        for reading in day {
            guard let identifier = reading.eventIdentifier, let start = reading.start,
                  DetachedOccurrenceSpan.seriesIdentifier(of: identifier) == seriesID,
                  onTheDay(start, isAllDay: reading.isAllDay), seen.insert(identifier).inserted else { continue }
            found.append(match(reading, identifier: identifier, start: start, kind: .shownThatDay))
        }
        for reading in series ?? [] {
            guard let identifier = reading.eventIdentifier, identifier != seriesID, let start = reading.start,
                  DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: reading.isDetached),
                  !seen.contains(identifier) else { continue }
            let kind: Kind
            if onTheDay(start, isAllDay: reading.isAllDay) {
                kind = .shownThatDay
            } else if onTheDay(slot(of: reading), isAllDay: seriesIsAllDay) {
                kind = .originallyThatDay
            } else {
                continue
            }
            seen.insert(identifier)
            found.append(match(reading, identifier: identifier, start: start, kind: kind))
        }
        return found.sorted { ($0.start, $0.identifier) < ($1.start, $1.identifier) }
    }

    /// #534: whether a requested excluded date still holds an occurrence of the existing series: the
    /// lookup resolved one (as before), or one edited on its own starts on that date. Only the day
    /// is read (`day` is not evaluated when the lookup hit); an occurrence moved off the date is not
    /// detected, the documented limit.
    static func stillPresent(lookupHit: Bool, onDay day: @autoclosure () -> [Reading], seriesID: String,
                             requested: Date, zone: TimeZone, host: TimeZone = .current) -> Bool {
        lookupHit || !matches(onDay: day(), listed: nil, seriesID: seriesID, seriesIsAllDay: false,
                              requested: requested, zone: zone, host: host).isEmpty
    }

    // MARK: - What the caller answers

    /// The answer for a lookup that missed: the refusal when an edited occurrence belongs to the
    /// day, else not found, with the requested day as a date (#535).
    static func miss(for call: Call, matches: [Match], identifier: String, requested: Date,
                     zone: TimeZone, host: TimeZone = .current) -> Miss {
        guard !matches.isEmpty else {
            return .notFound(detail: notFoundDetail(identifier: identifier, requested: requested, zone: zone))
        }
        return .refusal(reason(for: call, matches: matches, requested: requested, zone: zone, host: host))
    }

    /// #535: the detail of `eventNotFound` for a day with no occurrence. `identifier` is the one the
    /// caller passed. The day was printed as the date's own description, a UTC instant.
    static func notFoundDetail(identifier: String, requested: Date, zone: TimeZone) -> String {
        "\(identifier) (no occurrence on \(day(requested, in: zone)))"
    }

    /// `yyyy-MM-dd` of `date` in `zone`.
    static func day(_ date: Date, in zone: TimeZone) -> String {
        let parts = Calendar.gregorian(in: zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - The identifier

    static let maxIdentifierLength = 200
    private static let allowedIdentifierScalars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:/=-._@".unicodeScalars)

    /// The identifier as it may be written into a refusal, or nil.
    ///
    /// No other refusal puts an identifier read from the store into its text, and the reason is a
    /// trusted message that reaches the caller as it is. So an identifier is echoed only in a known
    /// shape: ASCII letters and digits and `: / = - . _ @`, at most 200 characters. Read so far (iCloud;
    /// Google through EventKit, 2026-11-13): two UUIDs joined by a colon, plus `/RID=` and digits.
    /// The dot, the underscore and the at sign allow a UID shape not read yet. Anything else loses
    /// the identifier and keeps the instruction (`list_events` shows it).
    static func echoed(_ identifier: String) -> String? {
        guard !identifier.isEmpty, identifier.unicodeScalars.count <= maxIdentifierLength,
              identifier.unicodeScalars.allSatisfy(allowedIdentifierScalars.contains),
              EventKitErrorSanitizer.sanitizeForInterpolation(identifier) == identifier else { return nil }
        return identifier
    }

    // MARK: - The refusal

    /// The refusal for `call`. `matches` holds at least one occurrence (`miss` asks only then). No title, calendar name or
    /// account is in the text, and no `<`, `>` or `&` (#166).
    static func reason(for call: Call, matches: [Match], requested: Date, zone: TimeZone, host: TimeZone = .current) -> String {
        let requestedDay = day(requested, in: zone)
        let futureSpan: Bool
        let ending: String
        switch call {
        case .update(let future): (futureSpan, ending) = (future, "Nothing was written.")
        case .delete(let future): (futureSpan, ending) = (future, "Nothing was deleted.")
        case .moveRow: (futureSpan, ending) = (false, "Nothing was moved.")
        }
        func startText(_ match: Match) -> String { OccurrenceStart.string(match.start, zone: match.isAllDay ? host : zone) }
        func startDay(_ match: Match) -> String { day(match.start, in: match.isAllDay ? host : zone) }
        /// It starts on another day than its slot's.
        func moved(_ match: Match) -> Bool { match.kind == .originallyThatDay || (match.originalDay.map { $0 != startDay(match) } ?? false) }

        guard let match = matches.first else {
            return "No occurrence of this series that was edited on its own belongs to \(requestedDay). \(ending)"
        }
        if matches.count == 1 {
            // With span future the original date matters (the series is cut there), so it is said.
            let original = futureSpan && moved(match) ? match.originalDay.map { " (its original date is \($0))" } ?? "" : ""
            let opening = match.kind == .shownThatDay
                ? "The occurrence of this series on \(requestedDay) was edited on its own\(original), so the series' identifier and that day no longer address it."
                : "The occurrence this series had on \(requestedDay) was edited on its own and now starts at \(startText(match))\(original), so the series' identifier and that day no longer address it."
            let identifier = echoed(match.identifier)
            let named = identifier.map { "Its identifier is \($0)." } ?? "Its identifier is the id list_events shows for it."
            switch call {
            case .update(futureSpan: false), .delete(futureSpan: false):
                let pass = identifier.map { "Its identifier is \($0): pass it as event_id and leave occurrence_date out." }
                    ?? "Use the id list_events shows for it as event_id and leave occurrence_date out."
                return "\(opening) \(pass) \(ending)"
            case .update:
                return "\(opening) \(named) With span 'future' through that identifier a call takes only some fields, and that call answers which. \(otherWay) \(ending)"
            case .delete:
                let from = match.originalDay.map { "original date, \($0), on" } ?? "original date on"
                return "\(opening) \(named) delete_event with span 'future' through that identifier deletes the series from that occurrence's \(from), where that call allows it, and that delete cannot be undone. \(ending)"
            case .moveRow:
                let entry = "with its occurrence_dates entry set to \(startDay(match)), the day it starts\(moved(match) ? " now" : "")."
                let pass = identifier.map { "Its identifier is \($0): pass it in event_ids, \(entry)" }
                    ?? "Use the id list_events shows for it in event_ids, \(entry)"
                return "\(opening) \(pass) \(ending)"
            }
        }

        let items = matches.map { match -> String in
            let name = echoed(match.identifier) ?? "one whose id list_events shows"
            let origin = futureSpan && match.kind == .shownThatDay && moved(match) ? match.originalDay.map { ", original date \($0)" } ?? "" : ""
            let detail = match.kind == .shownThatDay ? "starts at \(startText(match))\(origin)" : "was on that day, now starts at \(startText(match))"
            return "\(name) (\(detail))"
        }.joined(separator: "; ")
        let several = "More than one occurrence of this series that was edited on its own belongs to \(requestedDay): \(items). The series' identifier and a day do not address an occurrence edited on its own"
        switch call {
        case .update(futureSpan: false), .delete(futureSpan: false):
            return "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. \(ending)"
        case .update:
            return "\(several). With span 'future' through one of those identifiers a call takes only some fields, and that call answers which. \(otherWay) \(ending)"
        case .delete:
            return "\(several). delete_event with span 'future' through one of those identifiers deletes the series from that occurrence's original date on, where that call allows it, and that delete cannot be undone. \(ending)"
        case .moveRow:
            return "\(several): pass the identifier of the one you mean in event_ids, with its occurrence_dates entry set to the day it starts now. \(ending)"
        }
    }

    /// The other way for a span `future` update: span `this` on that occurrence, and for the later
    /// ones the route the refusal through an occurrence's own identifier names (#416), read from its
    /// constant. Neither refusal sends the caller back to the series' identifier with the edited
    /// occurrence's day, so the two do not loop.
    private static let otherWay = "For the rest: use span 'this' on that occurrence, and \(DetachedOccurrenceSpan.laterOccurrencesRoute)."
}

extension EditedOccurrenceAddress.Reading {
    init(_ event: EKEvent) {
        self.init(eventIdentifier: event.eventIdentifier, externalIdentifier: event.calendarItemExternalIdentifier,
                  occurrenceDate: event.occurrenceDate, isDetached: event.isDetached, isAllDay: event.isAllDay,
                  start: event.startDate)
    }
}
