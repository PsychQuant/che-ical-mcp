import EventKit
import Foundation

/// #532: a series' identifier and a day do not address an occurrence that was edited on its own.
///
/// Such an occurrence reads back with an identifier of its own (on iCloud and, through EventKit,
/// on Google: the series' identifier, `/RID=` and digits), while `findOccurrence` takes an event
/// only under the exact identifier it was given. So `update_event`, `delete_event` and
/// `move_events_batch` answered "not found" for a day on which the calendar shows an occurrence,
/// and `create_event` read an excluded date that still holds one as already excluded (#534).
///
/// The lookup stays as it is. When it misses, the callers ask this type which occurrences of the
/// series that were edited on their own start on the requested day, and answer a refusal that gives
/// each one's identifier, writing nothing. Only the day an occurrence starts on is read: nothing
/// here reads the slot the rule gave an occurrence (its `/RID=` digits or its `occurrenceDate`),
/// so an occurrence moved off the requested day is not found, as on `main`, and no text prints or
/// implies an original date. Reading that slot is #539's (PR #545 verify rounds 1 to 3: every
/// reading of it named an occurrence of another day in some shape of series).
///
/// Pure: events come in as `Reading` values and every zone is a parameter (`Request`).
enum EditedOccurrenceAddress {
    /// What was asked: a series' identifier and a day.
    struct Request: Equatable {
        /// The identifier the lookup used, the series' own.
        let seriesID: String
        let seriesIsAllDay: Bool
        /// The time zone the series has, as it is: nil for a series with none. No default is put in
        /// its place before it gets here: the day is then read in this Mac's zone (`zone`), and a
        /// timed series with none gets the text of #549 (`isFloating`).
        let seriesZone: TimeZone?
        let requested: Date
        /// This Mac's zone, in which all-day events are whole days (#364).
        var host: TimeZone = .current

        /// The zone the requested day was read in: the series', this Mac's for a series with none.
        var zone: TimeZone { seriesZone ?? host }
        /// A timed series with no time zone: there a span `future` delete through an edited
        /// occurrence's identifier answered `deleted` and left that occurrence (#549, measured on
        /// iCloud). Only the delete text reads this.
        var isFloating: Bool { !seriesIsAllDay && seriesZone == nil }
        /// The requested day, `yyyy-MM-dd`.
        var day: String { EditedOccurrenceAddress.day(requested, in: zone) }
    }

    /// What is read of one event of the requested day's window. Nothing else of it: no slot, no
    /// external identifier, no `isDetached`.
    struct Reading: Equatable {
        let eventIdentifier: String?
        let isAllDay: Bool
        let start: Date?
        /// The event's own time zone; nil for one with none.
        var timeZone: TimeZone? = nil
    }

    /// One occurrence edited on its own that starts on the requested day.
    struct Match: Equatable {
        /// The identifier `list_events` shows for it.
        let identifier: String
        let start: Date
        let isAllDay: Bool
        /// The occurrence's own time zone, in which a call through its identifier reads a date.
        var timeZone: TimeZone? = nil
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
        /// An edited occurrence starts on the day: the reason, a trusted message.
        case refusal(String)
        /// None was found: the detail of the not-found error (#535).
        case notFound(detail: String)
    }

    // MARK: - Which occurrences start on the day

    /// The occurrences of the series that were edited on their own and start on the requested day,
    /// each once, in the order of their starts.
    ///
    /// `day` holds every event the requested day's window holds, of any series. One is taken when
    /// its identifier is the series' identifier followed by `/RID=` (the exact series part, so a
    /// longer identifier with the same first characters is not) and it starts on the day, in the
    /// series' zone (this Mac's for a series with none, and for an all-day occurrence). The digits
    /// after `/RID=` are not read. On iCloud and Google (through EventKit, #320) every occurrence
    /// edited on its own has that identifier, the stand-in of a series whose first occurrence was
    /// deleted included (gate cell 7). An edited occurrence under an identifier of another shape,
    /// one tied to its series by the external identifier only, is not found (no such source was
    /// measured), and neither is one whose identifier is the series' own: the identifier would not
    /// address it. The caller then answers not found.
    static func matches(onDay day: [Reading], for request: Request) -> [Match] {
        var found: [Match] = []
        var seen: Set<String> = []
        for reading in day {
            guard let identifier = reading.eventIdentifier, let start = reading.start,
                  DetachedOccurrenceSpan.seriesIdentifier(of: identifier) == request.seriesID,
                  OccurrenceDay.startsOnRequestedDay(occurrenceStart: start, isAllDay: reading.isAllDay, requested: request.requested,
                                                     in: request.zone, host: request.host),
                  seen.insert(identifier).inserted else { continue }
            found.append(Match(identifier: identifier, start: start, isAllDay: reading.isAllDay, timeZone: reading.timeZone))
        }
        return found.sorted { ($0.start, $0.identifier) < ($1.start, $1.identifier) }
    }

    /// #534: what a requested excluded date still holds of the existing series.
    enum Presence: Equatable {
        case absent
        /// The lookup by the series' identifier resolved an occurrence (as before #534).
        case resolved
        /// An occurrence edited on its own starts on the date: edited in place, or moved onto it.
        case editedOccurrenceStarts
    }

    /// #534: whether a requested excluded date still holds an occurrence of the existing series.
    /// Only the day is read (`day` is not evaluated when the lookup hit), and only starts: no slot
    /// is read, so an occurrence moved onto the date counts and one moved off it is not detected,
    /// the documented limits. One is taken when its identifier is the series' identifier followed
    /// by `/RID=`; an edited occurrence under an identifier of another shape is not detected.
    static func presence(lookupHit: Bool, onDay day: @autoclosure () -> [Reading], seriesID: String,
                         requested: Date, zone: TimeZone?, host: TimeZone = .current) -> Presence {
        if lookupHit { return .resolved }
        let starts = day().contains { reading in
            guard let identifier = reading.eventIdentifier, DetachedOccurrenceSpan.seriesIdentifier(of: identifier) == seriesID else { return false }
            return OccurrenceDay.startsOnRequestedDay(occurrenceStart: reading.start, isAllDay: reading.isAllDay, requested: requested,
                                                      in: zone ?? host, host: host)
        }
        return starts ? .editedOccurrenceStarts : .absent
    }

    /// #534: the answer for `Presence.editedOccurrenceStarts`. True whether the occurrence was edited
    /// in place or moved onto the date, which "its exclusion set differs from the request" (the
    /// lookup's answer, kept as it is) is not. `date` is the excluded day as the caller's check
    /// prints it; nothing else is read from the store.
    static func exclusionReason(existingId: String, date: String) -> String {
        "An existing series (event ID \(existingId)) matches this event, and an occurrence of it that was edited on its own starts on \(date), a date this request excludes. Not modifying the existing series; adjust it explicitly or change the request."
    }

    // MARK: - What the caller answers

    /// The answer for a lookup that missed: the refusal when an edited occurrence starts on the
    /// day, else not found, with the requested day as a date (#535).
    static func miss(for call: Call, matches: [Match], request: Request) -> Miss {
        guard !matches.isEmpty else { return .notFound(detail: notFoundDetail(for: request)) }
        return .refusal(reason(for: call, matches: matches, request: request))
    }

    /// #535: the detail of `eventNotFound` for a day with no occurrence: the identifier the caller
    /// passed and the day in the zone it was read in. The day was printed as the date's own
    /// description, a UTC instant.
    static func notFoundDetail(for request: Request) -> String {
        "\(request.seriesID) (no occurrence on \(request.day))"
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
    /// trusted message that reaches the caller as it is. So an identifier is echoed only in the one
    /// shape that was read (iCloud; Google through EventKit, 2026-11-13): exactly the series'
    /// identifier the lookup used, `/RID=`, and ASCII digits. Every character of it is an ASCII
    /// letter or digit or one of `: / = - . _ @`, and it is at most 200 characters long. The series'
    /// identifier is the caller's own argument, so what the store adds is the marker and digits.
    /// The digits are checked to be digits and nothing more: they are not read as a date. Anything
    /// else loses the identifier and keeps the instruction (`list_events` shows it): a second
    /// `/RID=`, another character, no digits.
    static func echoed(_ identifier: String, seriesID: String) -> String? {
        let prefix = seriesID + DetachedOccurrenceSpan.slotMarker
        guard !seriesID.isEmpty, identifier.unicodeScalars.count <= maxIdentifierLength,
              identifier.unicodeScalars.allSatisfy(allowedIdentifierScalars.contains),
              identifier.hasPrefix(prefix) else { return nil }
        let digits = identifier.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return identifier
    }

    // MARK: - The refusal

    /// Where a span `future` call through an edited occurrence's identifier starts: at that
    /// occurrence's original date, which this server does not read (PR #545 narrowing round), so
    /// the text gives both directions. `day` is the requested day, `verb` "written" or "deleted".
    static func directions(day: String, verb: String) -> String {
        "This server does not read that date: when it is before \(day), occurrences of the series before \(day) are \(verb) too; when it is after \(day), the occurrences between \(day) and that date are not reached."
    }

    /// What was measured for `directions`, for the update and for the delete, without dates: an
    /// update (a title) and a delete through an occurrence moved later and one moved earlier
    /// (2026-11-13), and an update through one moved later in a series with no time zone (A2, 2026-11-14).
    static let measuredUpdate = "Measured on iCloud with a title, through an occurrence moved later and one moved earlier, and through one moved later in a series with no time zone."
    static let measuredDelete = "Measured on iCloud, through an occurrence moved later and one moved earlier."

    /// #550, said whatever the occurrence: where the store recorded an edited occurrence at another
    /// time of day than the series (measured on iCloud, 2026-11-14, in a series that got its time
    /// zone after its occurrences were edited), a span `future` update through its identifier
    /// (a title) moved the later occurrences of the series to another day, while span `this` with
    /// notes changed that occurrence only. This server does not read where the store recorded it.
    static let offTimeUpdate = "Where the store recorded that occurrence at another time of day than the series, a span 'future' update through its identifier moved the later occurrences of the series to another day (#550); span 'this' on that occurrence is the tested way."
    /// The same for a delete, worded to what #550 measured for it: a span `future` delete through
    /// such an identifier removed that occurrence and the later ones, and the occurrence the rule
    /// shows on that occurrence's day stayed. Span `this` was not measured for a delete there.
    static let offTimeDelete = "Where the store recorded that occurrence at another time of day than the series, a span 'future' delete through its identifier removed that occurrence and the later ones, and an occurrence the rule shows on its day stayed (#550)."
    /// #549, a known defect, measured on iCloud (2026-11-13): in a timed series with no time zone,
    /// a span `future` delete through the identifier of an edited occurrence deleted the later
    /// occurrences of the series, left that occurrence itself (edited in place or moved later)
    /// and answered `deleted`. Said only for such a series, where it was measured. This text and
    /// gate cell 8 change when #549 is fixed.
    static let leftBehind = "Known defect #549, measured on iCloud: in a series with no time zone that call answers deleted while that occurrence itself stays."

    /// The refusal for `call`. `matches` holds at least one occurrence (`miss` asks only then). No
    /// title, calendar name or account is in the text, and no `<`, `>` or `&` (#166). No date in it
    /// is an original date: every date is the requested day or a start.
    static func reason(for call: Call, matches: [Match], request: Request) -> String {
        let (zone, host, requestedDay) = (request.zone, request.host, request.day)
        let ending: String
        switch call {
        case .update: ending = "Nothing was written."
        case .delete: ending = "Nothing was deleted."
        case .moveRow: ending = "Nothing was moved."
        }
        func startText(_ match: Match) -> String { OccurrenceStart.string(match.start, zone: match.isAllDay ? host : zone) }
        /// The day it starts, in the series' zone, as the requested day is.
        func startDay(_ match: Match) -> String { day(match.start, in: match.isAllDay ? host : zone) }
        /// The day it starts in its own zone: a call through its identifier reads `occurrence_dates`
        /// there (`occurrenceZone` of the occurrence), not in the series' zone.
        func ownDay(_ match: Match) -> String { day(match.start, in: match.isAllDay ? host : match.timeZone ?? host) }
        func name(_ match: Match) -> String? { echoed(match.identifier, seriesID: request.seriesID) }
        /// The span `future` update text after the identifier, through `through` ("that identifier",
        /// or "one of those identifiers").
        func update(through: String) -> String {
            "With span 'future' through \(through) a call takes only some fields, and that call answers which. Such a call starts at that occurrence's original date. \(directions(day: requestedDay, verb: "written")) \(measuredUpdate) \(offTimeUpdate) \(otherWay)"
        }
        /// The same for the delete. In a timed series with no time zone it says what was measured
        /// there (#549), in which the occurrence itself stayed.
        func delete(through: String) -> String {
            let from = request.isFloating
                ? "deletes the occurrences of the series after that occurrence's original date"
                : "deletes the series from that occurrence's original date on"
            let defect = request.isFloating ? " \(leftBehind)" : ""
            return "delete_event with span 'future' through \(through), where that call allows it, \(from). \(directions(day: requestedDay, verb: "deleted")) \(measuredDelete)\(defect) \(offTimeDelete) That delete cannot be undone."
        }

        guard let match = matches.first else {
            return "No occurrence of this series that was edited on its own starts on \(requestedDay). \(ending)"
        }
        if matches.count == 1 {
            let opening = "An occurrence of this series that starts on \(requestedDay) was edited on its own, so the series' identifier and that day do not address it."
            let identifier = name(match)
            let named = identifier.map { "Its identifier is \($0)." } ?? "Its identifier is the id list_events shows for it."
            switch call {
            case .update(futureSpan: false), .delete(futureSpan: false):
                let pass = identifier.map { "Its identifier is \($0): pass it as event_id and leave occurrence_date out." }
                    ?? "Use the id list_events shows for it as event_id and leave occurrence_date out."
                return "\(opening) \(pass) \(ending)"
            case .update:
                return "\(opening) \(named) \(update(through: "that identifier")) \(ending)"
            case .delete:
                return "\(opening) \(named) \(delete(through: "that identifier")) \(ending)"
            case .moveRow:
                let own = ownDay(match)
                let ownZone = own == startDay(match) ? "" : " (the day in that occurrence's own time zone)"
                let entry = "with its occurrence_dates entry set to \(own), the day it starts\(ownZone)."
                let pass = identifier.map { "Its identifier is \($0): pass it in event_ids, \(entry)" }
                    ?? "Use the id list_events shows for it in event_ids, \(entry)"
                return "\(opening) \(pass) \(ending)"
            }
        }

        let items = matches.map { "\(name($0) ?? "one whose id list_events shows") (starts at \(startText($0)))" }.joined(separator: "; ")
        let several = "More than one occurrence of this series that was edited on its own starts on \(requestedDay): \(items). The series' identifier and a day do not address an occurrence edited on its own"
        switch call {
        case .update(futureSpan: false), .delete(futureSpan: false):
            return "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. \(ending)"
        case .update:
            return "\(several). \(update(through: "one of those identifiers")) \(ending)"
        case .delete:
            return "\(several). \(delete(through: "one of those identifiers")) \(ending)"
        case .moveRow:
            return "\(several): pass the identifier of the one you mean in event_ids, with its occurrence_dates entry set to the day it starts, read in that occurrence's own time zone. \(ending)"
        }
    }

    /// The other way for a span `future` update: span `this` on that occurrence, and for the later
    /// ones the route the refusal through an occurrence's own identifier names (#416), with that
    /// refusal's ending and its sentence on what that way leaves out, all read from its constants:
    /// the route is not one for every field. Neither refusal sends the caller back to the series'
    /// identifier with the edited occurrence's day, so the two do not loop.
    private static let otherWay = "For the rest: use span 'this' on that occurrence, and \(DetachedOccurrenceSpan.laterOccurrencesRoute). \(DetachedOccurrenceSpan.ifThatIdIsRefused) \(DetachedOccurrenceSpan.laterOccurrencesLimits)"
}

extension EditedOccurrenceAddress.Reading {
    init(_ event: EKEvent) {
        self.init(eventIdentifier: event.eventIdentifier, isAllDay: event.isAllDay, start: event.startDate, timeZone: event.timeZone)
    }
}
