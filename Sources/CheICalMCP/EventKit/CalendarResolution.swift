import EventKit
import Foundation

/// #604: how a call finds the one calendar it acts on, from a title, a source and a calendar `id`.
/// A pure function over any item type, so a test reads the decision without an EventKit store.
/// `EventKitManager.findCalendar` and `findCalendars` both go through it, so the read side and the
/// write side can no longer answer differently for the same calendars.
enum CalendarLookup {
    enum Outcome<Item> {
        /// Exactly one calendar.
        case found(Item)
        /// No calendar has the title, or the source, or the `id`.
        case notFound
        /// An `id` selected a calendar, and the title or source given beside it does not match it.
        case idMismatch
        /// No source was given and the title is shared by calendars of different accounts.
        case ambiguousAccounts([Item])
        /// More than one calendar of one account matches. Neither the title nor the source can tell
        /// them apart; only the `id` can.
        case ambiguousInAccount([Item])
    }

    /// - Parameters:
    ///   - all: the calendars of the kind the tool works on (event calendars or reminder lists)
    ///   - name: `calendar_name`; nil only when an `id` is given
    ///   - source: `calendar_source`
    ///   - id: `calendar_id`, which wins over the title and source but must agree with them
    static func resolve<Item>(_ all: [Item], name: String?, source: String?, id: String?,
                              identifier: (Item) -> String, title: (Item) -> String,
                              sourceTitle: (Item) -> String) -> Outcome<Item> {
        if let id {
            guard let selected = all.first(where: { identifier($0) == id }) else { return .notFound }
            if let name {
                // The title is compared as a lookup compares it (exact, then ignoring case), with the
                // source beside it when there is one.
                let agrees = !CalendarNameMatch.matching([selected], name: name, source: source,
                                                         title: title, sourceTitle: sourceTitle).isEmpty
                return agrees ? .found(selected) : .idMismatch
            }
            if let source, sourceTitle(selected).lowercased() != source.lowercased() { return .idMismatch }
            return .found(selected)
        }

        guard let name else { return .notFound }
        let matches = CalendarNameMatch.matching(all, name: name, source: source, title: title, sourceTitle: sourceTitle)
        guard let first = matches.first else { return .notFound }
        guard matches.count > 1 else { return .found(first) }
        // A name two accounts share needs the source; more than one in one account needs the id.
        if source == nil, Set(matches.map(sourceTitle)).count > 1 { return .ambiguousAccounts(matches) }
        return .ambiguousInAccount(matches)
    }
}

extension CalendarLookup {
    /// The one calendar a lookup acts on, or the refusal it throws. `candidates` gives the calendars of
    /// one kind, and only the kind asked for is read, so an `id` of the other kind is not found.
    /// - Parameter offersID: whether the tool this lookup serves takes `calendar_id`; it decides the
    ///   remedy of a same-name refusal.
    static func one<Item>(kind: EKEntityType, candidates: (EKEntityType) -> [Item], name: String?, source: String?,
                          id: String?, offersID: Bool, identifier: (Item) -> String, title: (Item) -> String,
                          sourceTitle: (Item) -> String) throws -> Item {
        let all = candidates(kind)
        switch resolve(all, name: name, source: source, id: id, identifier: identifier, title: title, sourceTitle: sourceTitle) {
        case .found(let calendar):
            return calendar
        case .notFound:
            if let id { throw EventKitError.calendarNotFound(identifier: id.isEmpty ? "(empty calendar_id)" : id) }
            let available = all.map { "\(title($0)) (\(sourceTitle($0)))" }
            if let source {
                throw EventKitError.calendarNotFoundWithSource(name: name ?? "", source: source, available: available)
            }
            throw EventKitError.calendarNotFound(identifier: name ?? "", available: available)
        case .idMismatch:
            throw EventKitError.calendarIDMismatch
        case .ambiguousAccounts(let calendars):
            throw EventKitError.multipleCalendarsFound(name: name ?? "", sources: calendars.map(sourceTitle).joined(separator: ", "))
        case .ambiguousInAccount(let calendars):
            throw EventKitError.sameNameCalendars(count: calendars.count, ids: CalendarCandidateIDs.listable(calendars.map(identifier)),
                                                  offersID: offersID)
        }
    }
}

/// #604: the calendar lists `list_calendars` reads for its `type`, in order, each with the name its
/// rows carry in `entity_types`.
enum CalendarKindLists {
    static func reads(for requested: EKEntityType?) -> [(type: EKEntityType, name: String)] {
        let events: (EKEntityType, String) = (.event, "event")
        let reminders: (EKEntityType, String) = (.reminder, "reminder")
        switch requested {
        case .event?: return [events]
        case .reminder?: return [reminders]
        default: return [events, reminders]
        }
    }
}

/// #604: which candidate `id`s a refusal may print. A refusal is built from store content that a
/// remote publisher can set (#37), so it prints an `id` only when every candidate's `id` is a plain
/// token; otherwise it prints none and the caller reads them from `list_calendars`.
enum CalendarCandidateIDs {
    static let longestListed = 64

    static func listable(_ ids: [String]) -> [String] {
        // By code point: a `Character` comparison also accepts a canonically equivalent look-alike,
        // such as the Kelvin sign for `K`.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".unicodeScalars)
        let plain = ids.allSatisfy { id in
            !id.isEmpty && id.unicodeScalars.count <= longestListed && id.unicodeScalars.allSatisfy(allowed.contains)
        }
        return plain ? ids : []
    }
}
