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
/// Pure: events come in as `Reading` values and every zone is a parameter (`Request`).
enum EditedOccurrenceAddress {
    /// What was asked: a series' identifier and a day.
    struct Request: Equatable {
        /// The identifier the lookup used, the series' own.
        let seriesID: String
        let seriesIsAllDay: Bool
        /// The time zone the series has, as it is: nil for a series with none. No default is put in
        /// its place before it gets here, because a timed series with none is read another way
        /// (`readsSlots`).
        let seriesZone: TimeZone?
        /// The start of the object the lookup used (the series, or the occurrence standing in for
        /// it): its time of day in the series' zone is the time of day of every slot the rule
        /// gives. nil when it is not known; no slot of a timed series is read then (`atTheSeriesTime`).
        let seriesStart: Date?
        let requested: Date
        /// This Mac's zone, in which all-day events are whole days (#364).
        var host: TimeZone = .current

        /// The zone the requested day was read in: the series', this Mac's for a series with none.
        var zone: TimeZone { seriesZone ?? host }
        /// Whether the slot of an edited occurrence can be read. Not for a timed series with no time
        /// zone: its `/RID=` is the slot's wall time read as UTC (#539), so read as an instant it is
        /// off by the host's offset, and on a host that is not UTC a request for a day with no
        /// occurrence named an occurrence of another day. Such a series is matched by the day an
        /// occurrence starts on only, and no original date is printed. #539 is to read that slot.
        /// A series whose zone was cleared after an occurrence was edited is fenced too, although
        /// that occurrence's `/RID=` is an instant (the safe side).
        var readsSlots: Bool { seriesIsAllDay || seriesZone != nil }
        /// Whether a slot read for a timed series is at the series' time of day in the series' zone.
        /// The rule keeps the wall time, so every slot it gives is. One that is not was not written
        /// for this series as it is now, and is not read (PR #545 verify round 2): a series that had
        /// no zone when an occurrence was edited and got one afterwards keeps that occurrence's
        /// `/RID=` as wall time read as UTC (measured on iCloud, 2026-11-14), which read as an
        /// instant named the occurrence for the day after it. The cost, on the same side: the slot
        /// is not read either when the whole series was moved to another time of day after the
        /// occurrence was edited, when the slot is in an hour a daylight-saving change skips, or
        /// when the series' start is not known.
        func atTheSeriesTime(_ slot: Date) -> Bool {
            guard let seriesZone, let seriesStart else { return false }
            let calendar = Calendar.gregorian(in: seriesZone)
            let time: Set<Calendar.Component> = [.hour, .minute, .second]
            return calendar.dateComponents(time, from: slot) == calendar.dateComponents(time, from: seriesStart)
        }
        /// The requested day, `yyyy-MM-dd`.
        var day: String { EditedOccurrenceAddress.day(requested, in: zone) }
    }

    /// What is read of one event: of each event of the requested day, and of each listed
    /// occurrence of the series.
    struct Reading: Equatable {
        let eventIdentifier: String?
        let externalIdentifier: String?
        let occurrenceDate: Date?
        let isDetached: Bool
        let isAllDay: Bool
        let start: Date?
        /// The event's own time zone; nil for one with none.
        var timeZone: TimeZone? = nil
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
        /// The day of the slot the rule gave it, `yyyy-MM-dd`, in the series' zone; nil when no slot
        /// is known or read (`Request.readsSlots`).
        let originalDay: String?
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
        /// An edited occurrence belongs to the day: the reason, a trusted message.
        case refusal(String)
        /// None was found: the detail of the not-found error (#535).
        case notFound(detail: String)
    }

    // MARK: - Which occurrences belong to the day

    /// The occurrences of the series that were edited on their own and belong to the requested day,
    /// each once, in the order of their starts.
    ///
    /// - `day`: every event the requested day's window holds, of any series. One is taken when its
    ///   identifier is the series' identifier followed by `/RID=` (the exact series part, so a
    ///   longer identifier with the same first characters is not) and it starts on the day.
    /// - `series`: the occurrences of the series listed over `listingRange(for:)`, already tied to it
    ///   by either identifier (`seriesOccurrences`), or nil when the series could not be listed. One
    ///   is taken when it is an occurrence edited on its own and starts on the day, or its slot is on
    ///   the day. This is the only way to one that was moved off the day, and to one a store ties to
    ///   its series by the external identifier alone. With nil, only the first list is read: nothing
    ///   is named that was not read (fail closed).
    ///
    /// An edited occurrence whose identifier is the series' own is not reported: the identifier
    /// would not address it (no such source was measured; the caller then answers not found).
    static func matches(onDay day: [Reading], listed series: [Reading]?, for request: Request) -> [Match] {
        let (zone, host) = (request.zone, request.host)
        func onTheDay(_ date: Date?, isAllDay: Bool) -> Bool {
            OccurrenceDay.startsOnRequestedDay(occurrenceStart: date, isAllDay: isAllDay, requested: request.requested, in: zone, host: host)
        }
        /// The slot the rule gave it; an all-day series' `/RID=` is a date, read in the host's zone.
        /// nil where slots are not read: a timed series with no zone, and in a timed series a slot
        /// that is not at the series' time of day.
        func slot(of reading: Reading) -> Date? {
            guard request.readsSlots else { return nil }
            let slot = UndoPostState.ruleSlot(eventIdentifier: reading.eventIdentifier, externalIdentifier: reading.externalIdentifier,
                                              occurrenceDate: reading.occurrenceDate, isAllDay: request.seriesIsAllDay, zone: host)
            guard !request.seriesIsAllDay else { return slot }
            return slot.flatMap { request.atTheSeriesTime($0) ? $0 : nil }
        }
        func match(_ reading: Reading, identifier: String, start: Date, kind: Kind) -> Match {
            Match(identifier: identifier, start: start, isAllDay: reading.isAllDay, kind: kind,
                  originalDay: slot(of: reading).map { self.day($0, in: request.seriesIsAllDay ? host : zone) },
                  timeZone: reading.timeZone)
        }

        var found: [Match] = []
        var seen: Set<String> = []
        for reading in day {
            guard let identifier = reading.eventIdentifier, let start = reading.start,
                  DetachedOccurrenceSpan.seriesIdentifier(of: identifier) == request.seriesID,
                  onTheDay(start, isAllDay: reading.isAllDay), seen.insert(identifier).inserted else { continue }
            found.append(match(reading, identifier: identifier, start: start, kind: .shownThatDay))
        }
        for reading in series ?? [] {
            guard let identifier = reading.eventIdentifier, identifier != request.seriesID, let start = reading.start,
                  DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: reading.isDetached),
                  !seen.contains(identifier) else { continue }
            let kind: Kind
            if onTheDay(start, isAllDay: reading.isAllDay) {
                kind = .shownThatDay
            } else if onTheDay(slot(of: reading), isAllDay: request.seriesIsAllDay) {
                kind = .originallyThatDay
            } else {
                continue
            }
            seen.insert(identifier)
            found.append(match(reading, identifier: identifier, start: start, kind: kind))
        }
        return found.sorted { ($0.start, $0.identifier) < ($1.start, $1.identifier) }
    }

    /// How far on each side of the requested day the series is listed.
    static let listingReach: TimeInterval = 366 * 86_400

    /// The range the series is listed over for `matches`: the requested day and `listingReach` on
    /// each side, about two years, well inside the four years one event query takes. It does not
    /// start at the series' first start: listed from there, a weekly series more than about five
    /// years old never reached the requested day, and an occurrence moved off it was not found
    /// (PR #545 verify). An occurrence moved further than this from the requested day is not found.
    static func listingRange(for request: Request) -> DateInterval? {
        guard let window = OccurrenceDay.candidateWindow(containing: request.requested, in: request.seriesZone, host: request.host) else { return nil }
        return DateInterval(start: window.start.addingTimeInterval(-listingReach), end: window.end.addingTimeInterval(listingReach))
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

    /// The answer for a lookup that missed: the refusal when an edited occurrence belongs to the
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
    /// Anything else loses the identifier and keeps the instruction (`list_events` shows it): one
    /// found through the listing under another prefix, a second `/RID=`, another character.
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

    /// The refusal for `call`. `matches` holds at least one occurrence (`miss` asks only then). No title, calendar name or
    /// account is in the text, and no `<`, `>` or `&` (#166).
    static func reason(for call: Call, matches: [Match], request: Request) -> String {
        let (zone, host, requestedDay) = (request.zone, request.host, request.day)
        let futureSpan: Bool
        let ending: String
        switch call {
        case .update(let future): (futureSpan, ending) = (future, "Nothing was written.")
        case .delete(let future): (futureSpan, ending) = (future, "Nothing was deleted.")
        case .moveRow: (futureSpan, ending) = (false, "Nothing was moved.")
        }
        func startText(_ match: Match) -> String { OccurrenceStart.string(match.start, zone: match.isAllDay ? host : zone) }
        /// The day it starts, in the series' zone, as the requested day and the original day are.
        func startDay(_ match: Match) -> String { day(match.start, in: match.isAllDay ? host : zone) }
        /// The day it starts in its own zone: a call through its identifier reads `occurrence_dates`
        /// there (`occurrenceZone` of the occurrence), not in the series' zone.
        func ownDay(_ match: Match) -> String { day(match.start, in: match.isAllDay ? host : match.timeZone ?? host) }
        /// It starts on another day than its slot's.
        func moved(_ match: Match) -> Bool { match.kind == .originallyThatDay || (match.originalDay.map { $0 != startDay(match) } ?? false) }
        /// Its original date, when it starts on the requested day and came from an earlier one: a
        /// span `future` call through its identifier starts there, before the requested day.
        func earlierOrigin(_ match: Match) -> String? {
            match.kind == .shownThatDay ? match.originalDay.flatMap { $0 < requestedDay ? $0 : nil } : nil
        }
        /// Where a span `future` write through the identifier of one moved occurrence starts, with
        /// what was measured on iCloud (2026-11-13, a title each time): at its original date, not at
        /// the day it starts now. Moved later, the write reached the occurrences from the original
        /// date on, the one between the two days too; moved earlier, it did not reach the ones
        /// between the two days. Nothing for an occurrence that was not moved, or whose original
        /// date is not read.
        func writeStart(_ match: Match) -> String {
            guard moved(match), let original = match.originalDay else { return "" }
            let start = " It starts at that occurrence's original date, \(original), not at "
            if match.kind == .originallyThatDay {
                return "\(start)the day it starts now (measured on iCloud with a title)."
            }
            return original < requestedDay
                ? "\(start)\(requestedDay): a title written that way reached the occurrences of the series from \(original) on (measured on iCloud)."
                : "\(start)\(requestedDay): a title written that way did not reach the occurrences of the series between \(requestedDay) and \(original) (measured on iCloud)."
        }
        /// Its original date, when it starts on the requested day and came from a later one: a span
        /// `future` delete through its identifier starts there, after the requested day, and takes
        /// the occurrence itself with it (measured on iCloud, 2026-11-13: the occurrence between the
        /// two days stayed).
        func laterOrigin(_ match: Match) -> String? {
            match.kind == .shownThatDay ? match.originalDay.flatMap { $0 > requestedDay ? $0 : nil } : nil
        }
        /// #549, a known defect, measured on iCloud (2026-11-13): in a timed series with no time
        /// zone, a span `future` delete through the identifier of an edited occurrence deleted the
        /// later occurrences of the series, left that occurrence itself (edited in place or moved)
        /// and answered `deleted`. This text and gate cell 8 change when #549 is fixed.
        let leftBehind = "Known defect #549, measured on iCloud: in such a series that call answers deleted while that occurrence itself stays."
        /// The same for a span `future` write in a timed series with no time zone: it starts at the
        /// occurrence's original date, which is not read here. Measured on iCloud (2026-11-14) with
        /// a title through the identifier of an occurrence moved past the next one: the title
        /// reached the occurrences after the original date, the one before the requested day among
        /// them, and the moved occurrence itself. Not measured for one edited in place or moved earlier.
        let unreadWriteStart = "It starts at that occurrence's original date, which this server does not read for a series with no time zone"
        func name(_ match: Match) -> String? { echoed(match.identifier, seriesID: request.seriesID) }

        guard let match = matches.first else {
            return "No occurrence of this series that was edited on its own belongs to \(requestedDay). \(ending)"
        }
        if matches.count == 1 {
            // With span future the original date matters (the series is cut there), so it is said.
            let original = futureSpan && moved(match) ? match.originalDay.map { " (its original date is \($0))" } ?? "" : ""
            let opening = match.kind == .shownThatDay
                ? "The occurrence of this series on \(requestedDay) was edited on its own\(original), so the series' identifier and that day no longer address it."
                : "The occurrence this series had on \(requestedDay) was edited on its own and now starts at \(startText(match))\(original), so the series' identifier and that day no longer address it."
            let identifier = name(match)
            let named = identifier.map { "Its identifier is \($0)." } ?? "Its identifier is the id list_events shows for it."
            switch call {
            case .update(futureSpan: false), .delete(futureSpan: false):
                let pass = identifier.map { "Its identifier is \($0): pass it as event_id and leave occurrence_date out." }
                    ?? "Use the id list_events shows for it as event_id and leave occurrence_date out."
                return "\(opening) \(pass) \(ending)"
            case .update:
                let start = request.readsSlots ? writeStart(match)
                    : " \(unreadWriteStart): if that date is earlier than \(requestedDay), occurrences before \(requestedDay) are written too. Measured on iCloud with a title, for an occurrence that was moved later: it reached the occurrences of the series after that occurrence's original date and that occurrence itself."
                return "\(opening) \(named) With span 'future' through that identifier a call takes only some fields, and that call answers which.\(start) \(otherWay) \(ending)"
            case .delete:
                if !request.readsSlots {
                    return "\(opening) \(named) delete_event with span 'future' through that identifier, where that call allows it, deletes the occurrences of the series after that occurrence's original date, which this server does not read for a series with no time zone: if that date is earlier than \(requestedDay), occurrences before \(requestedDay) are deleted too. \(leftBehind) That delete cannot be undone. \(ending)"
                }
                let from: String
                if let day = match.originalDay {
                    from = "original date, \(day), on, where that call allows it"
                        + (earlierOrigin(match).map { ", so the occurrences of the series from \($0) up to \(requestedDay) are deleted too" } ?? "")
                        + (laterOrigin(match).map { ", so that occurrence itself is deleted and the occurrences of the series between \(requestedDay) and \($0) stay (measured on iCloud)" } ?? "")
                } else {
                    from = "original date on, where that call allows it"
                }
                return "\(opening) \(named) delete_event with span 'future' through that identifier deletes the series from that occurrence's \(from), and that delete cannot be undone. \(ending)"
            case .moveRow:
                let own = ownDay(match)
                let ownZone = own == startDay(match) ? "" : " (the day in that occurrence's own time zone)"
                let entry = "with its occurrence_dates entry set to \(own), the day it starts\(moved(match) ? " now" : "")\(ownZone)."
                let pass = identifier.map { "Its identifier is \($0): pass it in event_ids, \(entry)" }
                    ?? "Use the id list_events shows for it in event_ids, \(entry)"
                return "\(opening) \(pass) \(ending)"
            }
        }

        let items = matches.map { match -> String in
            let origin = futureSpan && match.kind == .shownThatDay && moved(match) ? match.originalDay.map { ", original date \($0)" } ?? "" : ""
            let detail = match.kind == .shownThatDay ? "starts at \(startText(match))\(origin)" : "was on that day, now starts at \(startText(match))"
            return "\(name(match) ?? "one whose id list_events shows") (\(detail))"
        }.joined(separator: "; ")
        let several = "More than one occurrence of this series that was edited on its own belongs to \(requestedDay): \(items). The series' identifier and a day do not address an occurrence edited on its own"
        switch call {
        case .update(futureSpan: false), .delete(futureSpan: false):
            return "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. \(ending)"
        case .update:
            let reach = request.readsSlots
                ? " It starts at that occurrence's original date, which for one that was moved is not the day it starts now: a title written that way reached the occurrences of the series from the original date on (measured on iCloud)."
                : " \(unreadWriteStart): for one that was moved later, occurrences before the day it starts now are written too (measured on iCloud with a title, which reached that occurrence itself too)."
            return "\(several). With span 'future' through one of those identifiers a call takes only some fields, and that call answers which.\(reach) \(otherWay) \(ending)"
        case .delete:
            if !request.readsSlots {
                return "\(several). delete_event with span 'future' through one of those identifiers, where that call allows it, deletes the occurrences of the series after that occurrence's original date, which this server does not read for a series with no time zone: for one that was moved later, occurrences before the day it starts now are deleted too. \(leftBehind) That delete cannot be undone. \(ending)"
            }
            return "\(several). delete_event with span 'future' through one of those identifiers deletes the series from that occurrence's original date on, where that call allows it, so for one that was moved later the occurrences of the series from its original date up to the day it starts now are deleted too, and for one that was moved earlier that occurrence itself is deleted and the occurrences between the day it starts now and its original date stay, and that delete cannot be undone. \(ending)"
        case .moveRow:
            return "\(several): pass the identifier of the one you mean in event_ids, with its occurrence_dates entry set to the day it starts now, read in that occurrence's own time zone. \(ending)"
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
        self.init(eventIdentifier: event.eventIdentifier, externalIdentifier: event.calendarItemExternalIdentifier,
                  occurrenceDate: event.occurrenceDate, isDetached: event.isDetached, isAllDay: event.isAllDay,
                  start: event.startDate, timeZone: event.timeZone)
    }
}
