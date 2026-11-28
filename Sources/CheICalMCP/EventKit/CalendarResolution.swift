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

/// #604: which candidate `id`s a refusal may print. A refusal is built from store content that a
/// remote publisher can set (#37), so it prints an `id` only when every candidate's `id` is a plain
/// token; otherwise it prints none and the caller reads them from `list_calendars`.
enum CalendarCandidateIDs {
    static let longestListed = 64

    static func listable(_ ids: [String]) -> [String] {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let plain = ids.allSatisfy { !$0.isEmpty && $0.count <= longestListed && $0.allSatisfy(allowed.contains) }
        return plain ? ids : []
    }
}
